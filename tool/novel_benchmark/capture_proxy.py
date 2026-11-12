"""Local-only, transparent recording proxy for explicitly requested benchmark runs."""
import http.server
import json
import pathlib
import re
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


def route(path):
    match = re.fullmatch(r"/([a-z0-9-]+)/v1/(chat/completions|models)", path)
    if not match:
        raise ValueError("Invalid benchmark route")
    return match.group(1), "/v1/" + match.group(2)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.forward()

    def do_GET(self):
        self.forward()

    def log_message(self, *_):
        pass

    def forward(self):
        try:
            tag, endpoint = route(self.path)
        except ValueError:
            self.send_error(404)
            return
        directory = self.server.output / tag / "http"
        directory.mkdir(parents=True, exist_ok=True)
        stem = directory / f"{time.time_ns()}-{uuid.uuid4().hex[:8]}"
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        stem.with_suffix(".request.json").write_bytes(body or b"{}")
        started = time.monotonic()
        metadata = {"endpoint": endpoint, "startedAt": time.time(), "complete": False}
        connected = True
        try:
            request = urllib.request.Request(
                self.server.upstream + endpoint,
                data=body if self.command == "POST" else None,
                headers={"Content-Type": "application/json", "Authorization": "Bearer magpie"},
                method=self.command,
            )
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=900)
            except urllib.error.HTTPError as error:
                response = error
            with response, stem.with_suffix(".response").open("wb") as output:
                metadata["status"] = response.status
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.send_header("Connection", "close")
                self.end_headers()
                while chunk := response.read1(65536):
                    output.write(chunk)
                    output.flush()
                    if connected:
                        try:
                            self.wfile.write(chunk)
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError):
                            connected = False
                metadata["complete"] = True
        except Exception as error:
            metadata["error"] = str(error)
        finally:
            self.close_connection = True
            metadata.update(elapsedSeconds=time.monotonic() - started, clientConnected=connected)
            stem.with_suffix(".meta.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
            print(json.dumps({"tag": tag, **metadata}), flush=True)


def self_check():
    assert route("/sample-1/v1/chat/completions") == ("sample-1", "/v1/chat/completions")
    for invalid in ("/../v1/models", "/sample/v1/other", "/sample/v1/models?key=x"):
        try:
            route(invalid)
            raise AssertionError("Unsafe route accepted")
        except ValueError:
            pass
    payload = 'data: {"text":"中文"}\n\ndata: [DONE]\n\n'.encode()
    seen = []

    class Stub(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            seen.append(self.rfile.read(int(self.headers["Content-Length"])))
            self.send_response(200 if len(seen) == 1 else 429)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for byte in payload:
                self.wfile.write(bytes([byte]))

    with tempfile.TemporaryDirectory() as temporary:
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        proxy.output = pathlib.Path(temporary)
        proxy.upstream = f"http://127.0.0.1:{upstream.server_port}"
        threads = [threading.Thread(target=s.serve_forever) for s in (upstream, proxy)]
        for thread in threads:
            thread.start()
        try:
            for expected_status in (200, 429):
                request = urllib.request.Request(f"http://127.0.0.1:{proxy.server_port}/test/v1/chat/completions",
                                                 data=b'{"model":"stub"}')
                try:
                    response = urllib.request.urlopen(request)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    assert response.status == expected_status
                    assert response.read() == payload
            assert seen == [b'{"model":"stub"}'] * 2
        finally:
            for server in (proxy, upstream):
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()
        captures = sorted(proxy.output.glob("test/http/*.response"))
        assert len(captures) == 2 and all(p.read_bytes() == payload for p in captures)
        metadata = [json.loads(p.read_text()) for p in proxy.output.glob("test/http/*.meta.json")]
        assert len(metadata) == 2 and all(m["complete"] for m in metadata)
        assert sorted(m["status"] for m in metadata) == [200, 429]
    print("route, streaming bytes and HTTP error self-checks passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        self_check()
    else:
        output = pathlib.Path(sys.argv[1]).resolve()
        output.mkdir(parents=True, exist_ok=True)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.output = output
        server.upstream = "http://127.0.0.1:3425"
        (output / "proxy.json").write_text(json.dumps({"baseUrl": f"http://127.0.0.1:{server.server_port}"}))
        print(f"Capture proxy: 127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()
