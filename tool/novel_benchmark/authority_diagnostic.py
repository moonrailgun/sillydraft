"""Isolate non-prose context in captured reviews; never change book scores."""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
from pathlib import Path

from evaluate import digest, load_book, save
from evidence_diagnostic import ATOMIC, run_cell, user_data, validate


def prose_context(request):
    result = copy.deepcopy(request)
    data = user_data(result)
    data['写作上下文'] = [m for m in data['写作上下文'] if m['role'] == 'assistant']
    result['messages'][1]['content'] = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
    return result


def dependencies():
    return {name: digest(Path(__file__).with_name(name).read_text()) for name in
            ('authority_diagnostic.py', 'evidence_diagnostic.py', 'evaluate.py')}


def freeze(previous, output):
    prior = json.loads((previous / 'spec.json').read_text())
    book = load_book(previous.parent / 'sillydraft-v4-projection')
    output.mkdir(parents=True, exist_ok=False)
    requests = {}
    for case in prior['caseOrder']:
        path = previous / f'{case}-atomic.json'
        request = json.loads(path.read_text())
        assert request['messages'][0]['content'] == ATOMIC
        assert (previous / f'{case}-atomic-attempt-1/result.json').exists()
        transformed = prose_context(request)
        data = user_data(transformed)
        prose = [''.join(m['content'].values()).strip() for m in data['写作上下文']
                 if isinstance(m.get('content'), dict)]
        chapter = int(case.split('_')[0].removeprefix('chapter'))
        assert prose == [text.strip() for text in book[:chapter - 1]]
        assert data['本次正文'] == user_data(request)['本次正文']
        target = output / f'{case}-atomic.json'
        save(target, transformed)
        requests[case] = {'parent': str(path.resolve()), 'parentSha256': digest(path.read_text()),
                          'sha256': digest(target.read_text()),
                          'retainedPriorChapters': len(prose)}
    save(output / 'spec.json', {
        'createdAt': datetime.now().astimezone().isoformat(),
        'purpose': 'Development context-authority diagnostic, not book evaluation',
        'dependencies': dependencies(), 'requests': requests,
        'caseOrder': prior['caseOrder'], 'arms': ['atomic'],
        'limits': {'calls': 4, 'maxAttemptsPerCell': 2, 'concurrency': 2,
                   'outputTokens': 4096, 'temperature': 'unchanged, omitted'},
        'intervention': 'Only remove non-assistant writing-context messages. All prior accepted chapters verified in order against book. Current draft, IDs, atomic system and request parameters unchanged.',
        'comparator': str(previous.resolve()), 'expected': prior['expected'],
        'success': [
            'Detect both consequential chapter11/13 defects and at least one chapter11 date/count defect with matching IDs and verified reasons',
            'At least two additional actionable detections among original four positives versus whole-chapter atomic',
            'No flags for repaired defects or known negative controls; no new verified false positive',
            'All cells valid; manually check every adverse finding; valid cells never resampled',
        ],
        'boundary': [
            'Removes author constraints as well as generated summaries/plans; not a production replacement or a test of only plans',
            'Known development cases; shorter input and stochastic calls confound causal attribution',
            'Qualified weather/watermark allegations are not hard positives',
            'Curtain remains sealed; novels, product and book evaluator unchanged',
        ],
    })
    print('Frozen 4 context-only cells', flush=True)


def self_check():
    request = {'messages': [{'content': ATOMIC}, {'content': json.dumps({
        '本次正文': {'d1': 'draft'}, '写作上下文': [
            {'role': 'system', 'content': {'m0-p1': 'instruction'}},
            {'role': 'assistant', 'content': {'m1-p1': 'accepted prose'}},
            {'role': 'user', 'content': {'m2-p1': 'future plan'}}]})}], 'max_tokens': 4096}
    original = copy.deepcopy(request)
    result = prose_context(request)
    assert request == original
    data = user_data(result)
    assert data['写作上下文'] == [user_data(request)['写作上下文'][1]]
    assert data['本次正文'] == user_data(request)['本次正文']
    assert {k: v for k, v in result.items() if k != 'messages'} == {'max_tokens': 4096}
    finding = {'claims': [{'kind': 'payoff', 'claim': 'claim', 'passageIds': ['d1'],
                          'sourceIds': ['m1-p1'], 'verdict': 'uncertain', 'reason': 'reason'}]}
    validate(finding, result, 'atomic')
    finding['claims'][0]['sourceIds'] = ['m2-p1']
    try:
        validate(finding, result, 'atomic')
    except AssertionError:
        pass
    else:
        raise AssertionError('Accepted removed source ID')
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
        cells = [case for case in spec['caseOrder'] if args.only is None or args.only == case]
        assert cells
        for case in cells:
            assert digest((args.root / f'{case}-atomic.json').read_text()) == spec['requests'][case]['sha256']
            assert not list(args.root.glob(f'{case}-atomic-attempt-*/result.json')), 'Do not resample valid cells'
            if args.attempt > 1:
                assert args.only and (args.root / f'{case}-atomic-attempt-{args.attempt - 1}/invalid.json').exists()
        with ThreadPoolExecutor(max_workers=spec['limits']['concurrency']) as pool:
            futures = [pool.submit(run_cell, args.root, case, 'atomic', args.output, args.attempt) for case in cells]
            for future in futures:
                future.result()
