"""Offline checks for the supplementary evidence audit's trust boundary."""
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest

import audit_evidence as audit


class EvidenceAuditTest(unittest.TestCase):
    def setUp(self):
        self.sources = audit.number_sources(['首段。\n\n第二段。', '后章。'])
        self.good = {
            'checks': [{'id': 'money', 'verdict': 'met',
                        'reason': '此前收款与本次缺款分开记载。',
                        'sources': ['C01P0001', 'C02P0001']}],
            'findings': [],
            'scores': {d: {'score': 7, 'reason': '有据。',
                           'sources': ['C01P0001']} for d in audit.TARGET},
        }

    def test_numbering_preserves_every_character_and_chapter(self):
        for chapter, original in enumerate(['首段。\n\n第二段。', '后章。'], 1):
            self.assertEqual(''.join(text for key, text in self.sources.items()
                                     if key.startswith(f'C{chapter:02}')), original)

    def test_accepts_no_defects_without_forcing_a_finding(self):
        audit.validate(self.good, self.sources, ['money'])

    def test_rejects_unknown_sources_and_missing_required_check(self):
        for key in ('source', 'check'):
            bad = copy.deepcopy(self.good)
            if key == 'source':
                bad['checks'][0]['sources'] = ['C16P9999']
            else:
                bad['checks'] = []
            with self.assertRaises(AssertionError):
                audit.validate(bad, self.sources, ['money'])

    def test_cross_chapter_contradiction_requires_both_chapters(self):
        bad = copy.deepcopy(self.good)
        bad['findings'] = [{'kind': 'contradiction', 'severity': 'major',
                            'claim': '前后冲突。', 'sources': ['C01P0001'],
                            'countercheck': '未找到改变事实的事件。'}]
        with self.assertRaises(AssertionError):
            audit.validate(bad, self.sources, ['money'])
        bad['findings'][0]['sources'].append('C02P0001')
        audit.validate(bad, self.sources, ['money'])

    def test_nan_boolean_and_out_of_range_scores_are_rejected(self):
        for value in (float('nan'), True, 10.1):
            bad = copy.deepcopy(self.good)
            bad['scores']['causality']['score'] = value
            with self.assertRaises(AssertionError):
                audit.validate(bad, self.sources, ['money'])

    def test_failed_stream_is_preserved_and_cannot_overwrite_attempt(self):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'data: {"error":{"message":"incomplete"}}\n\n')

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                url = f'http://127.0.0.1:{server.server_port}'
                with self.assertRaisesRegex(AssertionError, 'Incomplete'):
                    audit.request_once(out, [], url, lambda _: None)
                self.assertFalse((out / 'result.json').exists())
                self.assertIn('incomplete', (out / 'response.sse').read_text())
                self.assertEqual(json.loads((out / 'invalid.json').read_text())['error'],
                                 'Incomplete or failed response')
                with self.assertRaisesRegex(AssertionError, 'already exists'):
                    audit.request_once(out, [], url, lambda _: None)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == '__main__':
    unittest.main()
