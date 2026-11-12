"""Freeze a model-only replay of the existing production review protocol."""
import argparse
from datetime import datetime
import json
from pathlib import Path

from evaluate import digest, save
from model_diagnostic import change_model, self_check


def dependencies():
    return {name: digest(Path(__file__).with_name(name).read_text()) for name in
            ('production_model_diagnostic.py', 'model_diagnostic.py',
             'evidence_diagnostic.py', 'evaluate.py')}


def freeze(previous, output):
    prior = json.loads((previous / 'spec.json').read_text())
    output.mkdir(parents=True, exist_ok=False)
    requests = {}
    for case in prior['caseOrder']:
        parent = previous / f'{case}-existing.json'
        comparator = previous / f'{case}-existing-attempt-1/result.json'
        request = json.loads(parent.read_text())
        changed = change_model(request)
        assert {k: v for k, v in changed.items() if k != 'model'} == {
            k: v for k, v in request.items() if k != 'model'}
        target = output / parent.name
        save(target, changed)
        requests[case] = {
            'parent': str(parent.resolve()), 'parentSha256': digest(parent.read_text()),
            'sha256': digest(target.read_text()), 'comparator': str(comparator.resolve()),
            'comparatorSha256': digest(comparator.read_text()),
        }
    save(output / 'spec.json', {
        'createdAt': datetime.now().astimezone().isoformat(),
        'purpose': 'Model-only diagnostic with unchanged production review protocol',
        'scriptSha256': dependencies()['evidence_diagnostic.py'],
        'dependencies': dependencies(), 'requests': requests,
        'caseOrder': prior['caseOrder'], 'arms': ['existing'],
        'limits': {'calls': 4, 'maxAttemptsPerCell': 2, 'concurrency': 2,
                   'outputTokens': 4096, 'temperature': 'unchanged, omitted'},
        'intervention': 'Only model changes to codex/gpt-6-astra. Original checks/issues protocol, three-issue cap, context, draft, IDs and parameters unchanged.',
        'expected': prior['expected'],
        'success': [
            'Actionable issues detect both consequential chapter11/13 claims and at least one chapter11 date/count error',
            'At least two additional verified detections versus001 existing across four predefined positives',
            'No known negative-control false positives; manually qualify every new adverse finding',
            'All cells valid; no valid resampling; invalid retry requires saved diagnosis',
        ],
        'boundary': [
            'Known development cases; no unseen accuracy or whole-book improvement claim',
            'Compare also004 atomic but do not claim randomized causal attribution',
            'No product configuration or writer changes; Gemini and Astra judges unchanged; curtain sealed',
        ],
    })
    verify(output)
    print('Frozen 4 model-only production-protocol cells')


def verify(root):
    spec = json.loads((root / 'spec.json').read_text())
    assert spec['dependencies'] == dependencies()
    for case, item in spec['requests'].items():
        assert digest((root / f'{case}-existing.json').read_text()) == item['sha256']
        for key in ('parent', 'comparator'):
            assert digest(Path(item[key]).read_text()) == item[f'{key}Sha256']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('command', choices=['freeze', 'verify', 'self-check'])
    parser.add_argument('root', type=Path, nargs='?')
    parser.add_argument('output', type=Path, nargs='?')
    args = parser.parse_args()
    if args.command == 'self-check':
        self_check()
    elif args.command == 'freeze':
        freeze(args.root, args.output)
    else:
        verify(args.root)
