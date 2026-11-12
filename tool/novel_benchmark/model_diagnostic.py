"""Isolate the reviewer model using frozen development requests."""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
from pathlib import Path

from evaluate import digest, save
from evidence_diagnostic import run_cell


def change_model(request):
    result = copy.deepcopy(request)
    assert result['model'] == 'tianji/kaon/gemini-4-argon'
    result['model'] = 'codex/gpt-6-astra'
    return result


def dependencies():
    return {name: digest(Path(__file__).with_name(name).read_text()) for name in
            ('model_diagnostic.py', 'evidence_diagnostic.py', 'evaluate.py')}


def freeze(previous, output):
    prior = json.loads((previous / 'spec.json').read_text())
    output.mkdir(parents=True, exist_ok=False)
    requests = {}
    for case in prior['caseOrder']:
        path = previous / f'{case}-atomic.json'
        comparator = previous / f'{case}-atomic-attempt-1/result.json'
        assert comparator.exists()
        request = json.loads(path.read_text())
        result = change_model(request)
        assert {k: v for k, v in result.items() if k != 'model'} == {
            k: v for k, v in request.items() if k != 'model'}
        target = output / f'{case}-atomic.json'
        save(target, result)
        requests[case] = {'parent': str(path.resolve()),
                          'parentSha256': digest(path.read_text()),
                          'sha256': digest(target.read_text()),
                          'comparator': str(comparator.resolve()),
                          'comparatorSha256': digest(comparator.read_text())}
    save(output / 'spec.json', {
        'createdAt': datetime.now().astimezone().isoformat(),
        'purpose': 'Reviewer model dependence diagnostic, not book evaluation',
        'dependencies': dependencies(), 'requests': requests,
        'caseOrder': prior['caseOrder'], 'arms': ['atomic'],
        'limits': {'calls': 4, 'maxAttemptsPerCell': 2, 'concurrency': 2,
                   'outputTokens': 4096, 'temperature': 'unchanged, omitted'},
        'intervention': 'Only model changes to codex/gpt-6-astra. Full original context, draft, IDs, atomic prompt and parameters unchanged.',
        'expected': prior['expected'], 'success': prior['success'],
        'boundary': [
            'Known development cases, one sample per cell; no unseen accuracy or whole-book improvement claim',
            'Backend models and their interpretation of the same token limit may differ',
            'Changing production reviewer model would require a separate design and equal-input comparison',
            'Gemini writer and Gemini plus Astra external judges unchanged; curtain sealed',
        ],
    })
    print('Frozen 4 model-only cells', flush=True)


def self_check():
    request = {'model': 'tianji/kaon/gemini-4-argon', 'messages': [{'content': 'original'}],
               'max_tokens': 4096, 'stream': True}
    original = copy.deepcopy(request)
    result = change_model(request)
    assert request == original
    assert result.pop('model') == 'codex/gpt-6-astra'
    original.pop('model')
    assert result == original
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
                assert (args.root / f'retry-diagnosis-{case}.json').exists()
        with ThreadPoolExecutor(max_workers=spec['limits']['concurrency']) as pool:
            futures = [pool.submit(run_cell, args.root, case, 'atomic', args.output, args.attempt)
                       for case in cells]
            for future in futures:
                future.result()
