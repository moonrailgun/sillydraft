"""Offline application of the frozen continuity benchmark's acceptance rule."""
import argparse
import json
from pathlib import Path
import statistics
from evaluate import DIMENSIONS, summarize

TARGET = ('continuity', 'causality', 'payoff')


def aggregate(rows, judges, candidate, reference):
    assert candidate != reference
    assert len(judges) == 2 and len(set(judges)) == 2
    assert all(r['source'] in (candidate, reference) and r['judge'] in judges
               and r['order'] in (0, 1) for r in rows)
    assert len({(r['judge'], r['order'], r['attempt'], r['source']) for r in rows}) == len(rows)
    result = {'candidate': candidate, 'reference': reference, 'judges': [], 'rows': rows}
    for judge in judges:
        cells = []
        for order in (0, 1):
            cell = {'order': order, 'books': {}}
            attempts = []
            for source in (candidate, reference):
                subset = [r for r in rows if (r['judge'], r['order'], r['source']) == (judge, order, source)]
                attempts.append({r['attempt'] for r in subset})
                if subset:
                    scores = {d: statistics.mean(r['scores'][d] for r in subset) for d in DIMENSIONS}
                    cell['books'][source] = {'attempts': sorted(attempts[-1]), 'scores': scores,
                        'overall': statistics.mean(scores.values()),
                        'target': statistics.mean(scores[d] for d in TARGET)}
            assert attempts[0] == attempts[1], 'Each valid attempt must contain both books'
            cells.append(cell)
        item = {'judge': judge, 'orders': cells, 'complete': all(len(c['books']) == 2 for c in cells)}
        if item['complete']:
            books = {s: {d: statistics.mean(c['books'][s]['scores'][d] for c in cells)
                         for d in DIMENSIONS} for s in (candidate, reference)}
            gaps = {d: books[candidate][d] - books[reference][d] for d in DIMENSIONS}
            overall = statistics.mean(gaps.values())
            target = statistics.mean(gaps[d] for d in TARGET)
            item.update({'scores': books, 'gaps': gaps, 'overallGap': overall,
                         'targetGap': target, 'passes': min(overall, target) >= -0.3 - 1e-9})
        else:
            item['passes'] = False
        result['judges'].append(item)
    result['complete'] = all(j['complete'] for j in result['judges'])
    result['passes'] = all(j['passes'] for j in result['judges'])
    return result


def self_check():
    rows = [{'judge': j, 'order': o, 'attempt': 1, 'source': s,
             'scores': {d: 6.7 if s == 'candidate' else 7.0 for d in DIMENSIONS}}
            for j in ('gemini', 'astra') for o in (0, 1) for s in ('candidate', 'reference')]
    check = lambda data: aggregate(data, ['gemini', 'astra'], 'candidate', 'reference')
    assert check(rows)['passes']
    assert not check(rows[:-2])['complete']
    bad = json.loads(json.dumps(rows))
    for r in bad:
        if r['judge'] == 'astra' and r['source'] == 'candidate':
            for d in TARGET:
                r['scores'][d] = 6.6
    assert not check(bad)['passes']
    extra = [{**r, 'attempt': 2, 'scores': {d: 8.0 if r['source'] == 'candidate' else 7.0
                                          for d in DIMENSIONS}} for r in rows if r['order'] == 0]
    out = check(rows + extra)
    assert abs(out['judges'][0]['overallGap'] - 0.025) < 1e-9
    assert check(list(reversed(rows))) == {**check(rows), 'rows': list(reversed(rows))}
    print('Missing cells, per-judge thresholds, order balance and all-attempt weighting passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('directory', nargs='?', type=Path)
    parser.add_argument('candidate', nargs='?', type=Path)
    parser.add_argument('--self-check', action='store_true')
    args = parser.parse_args()
    if args.self_check:
        self_check()
    else:
        assert args.directory and args.candidate
        manifest = json.loads((args.directory / 'unblinding.json').read_text())
        candidate = str(args.candidate.resolve())
        sources = set(manifest['mapping']['0'].values())
        assert len(sources) == 2 and candidate in sources
        output = aggregate(summarize(args.directory)['rows'], manifest['judges'], candidate,
                           next(iter(sources - {candidate})))
        output['invalidAttempts'] = [p.name for p in sorted(args.directory.glob('*.invalid.json'))]
        print(json.dumps(output, ensure_ascii=False, indent=2))
