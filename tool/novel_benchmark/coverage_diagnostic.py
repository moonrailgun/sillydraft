"""Test fixed contiguous review windows without changing novels or book scores."""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
from pathlib import Path

from evaluate import digest, save
from evidence_diagnostic import ATOMIC, run_cell, user_data, validate


def windows(request, size=12):
    data = user_data(request)
    draft = list(data['本次正文'].items())
    assert draft and size > 0
    for start in range(0, len(draft), size):
        body = copy.deepcopy(data)
        body['本次正文'] = dict(draft[start:start + size])
        body['写作上下文'].append({
            'role': 'assistant',
            'description': '本次章节全文，仅供同章核对；不是前章，也不是新的事实来源。',
            'content': {f'mCurrent-p{i + 1}': text for i, (_, text) in enumerate(draft)},
        })
        result = copy.deepcopy(request)
        result['messages'][1]['content'] = json.dumps(body, ensure_ascii=False, separators=(',', ':'))
        yield result


def dependencies():
    return {name: digest(Path(__file__).with_name(name).read_text()) for name in
            ('coverage_diagnostic.py', 'evidence_diagnostic.py', 'evaluate.py')}


def freeze(previous, output):
    prior = json.loads((previous / 'spec.json').read_text())
    cells = {}
    parents = {}
    for case in prior['caseOrder']:
        path = previous / f'{case}-atomic.json'
        request = json.loads(path.read_text())
        assert request['messages'][0]['content'] == ATOMIC
        assert request['max_tokens'] == 4096
        assert request['model'] == 'tianji/kaon/gemini-4-argon'
        assert (previous / f'{case}-atomic-attempt-1/result.json').exists()
        parents[case] = {'path': str(path.resolve()), 'sha256': digest(path.read_text())}
        for index, part in enumerate(windows(request)):
            cells[f'{case}-window{index + 1:02}'] = part
    output.mkdir(parents=True, exist_ok=False)
    requests = {}
    for cell, request in cells.items():
        path = output / f'{cell}-atomic.json'
        save(path, request)
        requests[cell] = {'sha256': digest(path.read_text()),
                          'passageIds': list(user_data(request)['本次正文'])}
    save(output / 'spec.json', {
        'createdAt': datetime.now().astimezone().isoformat(),
        'purpose': 'Development coverage diagnostic, not book quality evaluation',
        'dependencies': dependencies(), 'parents': parents, 'requests': requests,
        'arms': ['atomic'], 'caseOrder': list(cells),
        'limits': {'calls': len(cells), 'maxAttemptsPerCell': 2, 'concurrency': 2,
                   'outputTokens': 4096, 'temperature': 'omitted as in original captures'},
        'intervention': 'Every 12 draft passages in original order, no overlap or target selection. Unchanged atomic system; full current chapter appended as same-chapter reference alongside unchanged full writing context.',
        'comparator': str(previous.resolve()),
        'expected': prior['expected'],
        'success': [
            'Detect both consequential chapter11/13 defects and at least one chapter11 date/count defect, with matching passage IDs and verified reasons',
            'At least two additional verified detections among the original four positives compared with whole-chapter atomic review',
            'No flags for the three repaired defects or other known negative controls; no newly verified false positive',
            'All cells valid and every adverse finding manually checked; valid cells never resampled',
        ],
        'boundary': [
            'Fixed windows test attention allocation plus repeated calls, not a pure prompt or compute-controlled causal estimate',
            'Known development cases; no claim of unseen accuracy or full-book improvement',
            'Qualified weather/watermark allegations are not predeclared hard positives',
            'Curtain prose and semantic judgments remain sealed; product source unchanged',
        ],
    })
    print(f'Frozen {len(cells)} cells', flush=True)


def self_check():
    request = {'messages': [{'content': ATOMIC}, {'content': json.dumps({
        '本次正文': {f'd{i}': f'paragraph {i}' for i in range(1, 26)},
        '写作上下文': [{'content': {'m0-p1': 'original source'}}],
    })}], 'max_tokens': 4096}
    original = copy.deepcopy(request)
    parts = list(windows(request))
    assert request == original and len(parts) == 3
    assert [len(user_data(p)['本次正文']) for p in parts] == [12, 12, 1]
    assert [k for p in parts for k in user_data(p)['本次正文']] == list(user_data(request)['本次正文'])
    for part in parts:
        body = user_data(part)
        assert body['写作上下文'][0] == user_data(request)['写作上下文'][0]
        assert list(body['写作上下文'][-1]['content'].values()) == list(user_data(request)['本次正文'].values())
        result = {'claims': [{'kind': 'payoff', 'claim': 'claim',
            'passageIds': [next(iter(body['本次正文']))], 'sourceIds': ['mCurrent-p25'],
            'verdict': 'uncertain', 'reason': 'needs context'}]}
        validate(result, part, 'atomic')
    invalid = copy.deepcopy(result)
    invalid['claims'][0]['passageIds'] = ['d1']
    try:
        validate(invalid, parts[-1], 'atomic')
    except AssertionError:
        pass
    else:
        raise AssertionError('Accepted an out-of-window target')
    print('self-check passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('command', choices=['freeze', 'run', 'self-check'])
    parser.add_argument('root', type=Path, nargs='?')
    parser.add_argument('output', nargs='?')
    parser.add_argument('--only')
    parser.add_argument('--attempt', type=int, default=1)
    args = parser.parse_args()
    if args.command == 'self-check':
        self_check()
    elif args.command == 'freeze':
        freeze(args.root, Path(args.output))
    else:
        spec = json.loads((args.root / 'spec.json').read_text())
        assert dependencies() == spec['dependencies']
        assert 1 <= args.attempt <= spec['limits']['maxAttemptsPerCell']
        cells = [c for c in spec['caseOrder'] if args.only is None or c == args.only]
        assert cells
        for cell in cells:
            assert digest((args.root / f'{cell}-atomic.json').read_text()) == spec['requests'][cell]['sha256']
            assert not list(args.root.glob(f'{cell}-atomic-attempt-*/result.json')), 'Do not resample valid cells'
            if args.attempt > 1:
                assert args.only and (args.root / f'{cell}-atomic-attempt-{args.attempt - 1}/invalid.json').exists()
        with ThreadPoolExecutor(max_workers=spec['limits']['concurrency']) as pool:
            futures = [pool.submit(run_cell, args.root, cell, 'atomic', args.output, args.attempt) for cell in cells]
            for future in futures:
                future.result()
