"""Run a compiled, isolated crash probe; never crash the application or library."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--probe", type=Path)
    source.add_argument("--build", type=Path, help="Configured Windows CMake build directory")
    args = parser.parse_args()
    if args.build:
        build = args.build.resolve(strict=True)
        cache = (build / "CMakeCache.txt").read_text(encoding="utf-8")
        cmake = next(line.split("=", 1)[1] for line in cache.splitlines()
                     if line.startswith("CMAKE_COMMAND:INTERNAL="))
        subprocess.run([cmake, "--build", str(build), "--config", "Release",
                        "--target", "sillydraft_crash_probe"], check=True)
        probe = (build / "crash-test/Release/sillydraft_crash_probe.exe").resolve(strict=True)
    else:
        probe = args.probe.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="sillydraft-crash-") as temp:
        directory = Path(temp) / "日志 with spaces"
        for mode, expected in (("exception", "0xC0000005"), ("abort", "SIGABRT"), ("normal", "probe")):
            target = directory / mode
            result = subprocess.run([str(probe), str(target), mode], timeout=15)
            assert (result.returncode == 0) == (mode == "normal"), result.returncode
            logs = list(target.glob("native-*.log"))
            assert len(logs) == 1, logs
            content = logs[0].read_text(encoding="utf-8")
            assert expected in content, content
            if mode == "exception":
                assert "module=" in content and "offset=" in content, content
                assert probe.name in content, content
            print(f"PASS: {mode} (exit {result.returncode})")
        # Retention must preserve unrelated files and Dart logs.
        keep = directory / "normal" / "errors-keep.log"
        keep.write_text("keep", encoding="utf-8")
        for _ in range(12):
            subprocess.run([str(probe), str(keep.parent), "normal"], check=True, timeout=15)
        assert len(list(keep.parent.glob("native-*.log"))) <= 10
        assert keep.read_text(encoding="utf-8") == "keep"
        print("PASS: retention")


if __name__ == "__main__":
    main()
