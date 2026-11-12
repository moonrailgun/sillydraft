"""Local-only checks for numbered evidence and the shared judging transport."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest

import evaluate
import evaluate_sources as subject


def books():
    return {label: [f'{label} 第{n}章完整正文。\n\n下一段。' for n in range(1, 17)]
            for label in ('A', 'B')}


def judgment():
    return {'winner': 'tie', 'comparison': '比较', 'books': {
        label: {'adherence': '完整', 'strength': '优点', 'weakness': '缺点', 'scores': {
            d: {'score': 7, 'reason': '依据', 'sources': [f'{label}:C{n:02}P0001']}
            for d, n in zip(evaluate.DIMENSIONS, (1, 4, 8, 12, 16, 4, 8, 16))}}
        for label in ('A', 'B')}}


class EvidenceTests(unittest.TestCase):
    def test_numbering_preserves_every_character_and_resolves_full_paragraph(self):
        data = books()
        data['A'][0] = '\n\n' + '很长的原文' * 100 + '\r\n\n尾段\n'
        sources = subject.sources_for(data)
        for label, chapters in data.items():
            for n, chapter in enumerate(chapters, 1):
                self.assertEqual(chapter, ''.join(v for k, v in sources.items()
                                                if k.startswith(f'{label}:C{n:02}P')))
        result = judgment()
        result['books']['A']['scores']['prose']['sources'] = ['A:C01P0002']
        resolved = subject.validate(result, data)
        self.assertEqual(resolved['A:C01P0002']['text'], '很长的原文' * 100 + '\r\n\n')
        self.assertEqual(resolved['A:C01P0002']['chapter'], 1)
        self.assertNotIn('evidence', result['books']['A']['scores']['prose'])

    def test_rejects_unknown_cross_book_blank_duplicate_and_empty_references(self):
        data = books()
        data['A'][0] = '\n正文。'
        for refs in (['A:C99P0001'], ['B:C01P0001'], ['A:C01P0001'],
                     ['A:C02P0001', 'A:C02P0001'], [], 'A:C02P0001'):
            with self.subTest(refs=refs):
                result = judgment()
                result['books']['A']['scores']['prose']['sources'] = refs
                with self.assertRaises(AssertionError):
                    subject.validate(result, data)

    def test_rejects_invalid_scores_and_insufficient_coverage(self):
        for value in (True, -1, 11, float('nan'), '7'):
            result = judgment()
            result['books']['A']['scores']['prose']['score'] = value
            with self.assertRaises(AssertionError):
                subject.validate(result, books())
        for chapters in ((1, 2, 3, 4), (1, 8, 16)):
            result = judgment()
            for label, book in result['books'].items():
                for dimension in book['scores'].values():
                    dimension['sources'] = [f'{label}:C{n:02}P0001' for n in chapters]
            with self.assertRaises(AssertionError):
                subject.validate(result, books())

    def test_prompt_contains_all_sources_without_old_copy_requirement(self):
        messages = subject.prompt({'id': 'test'}, books())
        self.assertNotIn('必须逐字复制', messages[0]['content'])
        self.assertIn('0=完全失败，3=重大问题', messages[0]['content'])
        for key, paragraph in subject.sources_for(books()).items():
            self.assertIn(f'[{key}]\n{paragraph}', messages[1]['content'])
        self.assertNotIn('"quote"', messages[1]['content'])

    def test_legacy_prompt_remains_byte_identical(self):
        actual = evaluate.digest(json.dumps(evaluate.prompt({'id': 'test'}, books()), ensure_ascii=False))
        self.assertEqual(actual, '25768457fe5e097959b5af79a3feeb21dc02489a8c513b78c9e91642cef55a21')

    def test_local_transport_counterbalance_resolution_and_failure_retention(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(request)
                output = judgment()
                prompt_text = request['messages'][1]['content']
                for label in ('A', 'B'):
                    value = 8 if f'[{label}:C01P0001]\n左书 第1章' in prompt_text else 6
                    for item in output['books'][label]['scores'].values():
                        item['score'] = value
                content = '{invalid' if request['model'] == 'invalid' else json.dumps(output)
                body = ('data: ' + json.dumps({'choices': [{'index': 0, 'delta': {'content': content},
                                                         'finish_reason': 'stop'}]}) + '\n\n'
                        'data: [DONE]\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = {'judges': ['mock0', 'mock1'], 'stories': [{'id': 'test'}]}
            evaluate.save(root / 'fixture.json', fixture)
            for name, text in (('left', '左书'), ('right', '右书')):
                (root / name).mkdir()
                evaluate.save(root / name / 'fixture.json', fixture)
                for n in range(1, 17):
                    (root / name / f'{n:02}.txt').write_text(f'{text} 第{n}章\n')
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                args = SimpleNamespace(fixture=root / 'fixture.json', story='test', left=root / 'left',
                    right=root / 'right', output=root / 'judging', attempt=1, only=None,
                    base_url=f'http://127.0.0.1:{server.server_port}')
                subject.judge(args)
                rows = evaluate.summarize(args.output)['rows']
                self.assertEqual(len(rows), 8)
                for row in rows:
                    self.assertEqual(row['overall'], 8 if row['source'] == str(args.left.resolve()) else 6)
                self.assertEqual(len(list(args.output.glob('*.resolved.json'))), 4)
                self.assertEqual(len(requests), 4)
                self.assertTrue(all(r['temperature'] == 0.2 and r['max_tokens'] == 20000 for r in requests))
                manifest = json.loads((args.output / 'unblinding.json').read_text())
                self.assertIn('protocol', manifest)
                subject.judge(args)
                self.assertEqual(len(requests), 4, 'Completed attempts must not send new requests')
                fixture['judges'][0] = 'invalid'
                for path in (args.fixture, args.left / 'fixture.json', args.right / 'fixture.json'):
                    evaluate.save(path, fixture)
                args.output = root / 'failed'
                args.only = ['0:0']
                with self.assertRaises(AssertionError):
                    subject.judge(args)
                self.assertEqual(len(list(args.output.glob('*.invalid.json'))), 1)
                self.assertEqual(len(list(args.output.glob('*.response'))), 1)
                self.assertFalse(list(args.output.glob('*.judgment.json')))
                args.attempt = 4
                with self.assertRaises(AssertionError):
                    subject.judge(args)
                self.assertEqual(len(requests), 5)
            finally:
                server.shutdown()
                server.server_close()
                worker.join()


if __name__ == '__main__':
    unittest.main()
