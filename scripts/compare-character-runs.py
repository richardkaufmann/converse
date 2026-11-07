#!/usr/bin/env python3
"""Compare retained per-character captures; refuse mismatched workloads."""
import argparse
import json
import math
from pathlib import Path


def load(folder):
    folder = Path(folder)
    workload = json.loads((folder / 'workload.json').read_text())
    report = json.loads((folder / 'Performance Diagnostics/characters.json').read_text())
    if report.get('schemaVersion') != 1:
        raise ValueError('Unsupported character report schema')
    for key, report_key in [('count', 'countPerLane'), ('intervalSeconds', 'intervalSeconds'), ('historyLines', 'historyLines')]:
        if workload[key] != report[report_key]:
            raise ValueError(f'Workload/report disagree: {key}')
    if workload.get('mouseHertz', 0) != report.get('mouseStress', {}).get('hertz', 0) or workload.get('webImage', False) != report.get('webImage', False):
        raise ValueError('Workload/report disagree: mouse or image scenario')
    return workload, report


def compare(a, b):
    wa, ra = a
    wb, rb = b
    for key in ['count', 'intervalSeconds', 'historyLines', 'positiveControlMilliseconds', 'fixtureSHA256', 'endpoint']:
        if wa[key] != wb[key]:
            raise ValueError(f'Cannot compare different workloads: {key}')
    for key, default in [('mouseHertz', 0), ('webImage', False)]:
        if wa.get(key, default) != wb.get(key, default):
            raise ValueError(f'Cannot compare different workloads: {key}')
    lines = [f"A binary: {wa['appSHA256']}", f"B binary: {wb['appSHA256']}",
             f"{wa['count']} characters per lane; {wa['intervalSeconds']} s cadence; {wa['historyLines']} history lines",
             'Lane        Drawn A/B       p95 A/B ms          max A/B ms']
    if wa.get('mouseHertz', 0):
        for name, report in [('A', ra), ('B', rb)]:
            mouse = report.get('mouseStress', {})
            if not mouse.get('trackingInitialized', False):
                lines.append(f'INVALID hover comparison: {name} did not explicitly initialize tracking in the synthetic fixture.')
            if mouse.get('skippedNoView', 0) or mouse.get('scheduled', 0) != sum(mouse.get(k, 0) for k in ['delivered', 'skippedNoTracking', 'skippedNoView']):
                lines.append(f'INCOMPLETE hover comparison: {name} has missing or invisible dispatches.')
    for lane in ['input', 'provider']:
        values = []
        for report in [ra, rb]:
            rows = [row for row in report['characters'] if row['lane'] == lane]
            sequences = [row['sequence'] for row in rows]
            if len(set(sequences)) != len(sequences) or any(n not in range(wa['count']) for n in sequences):
                raise ValueError('Invalid character sequence')
            durations = sorted((row['drawn'] - row['scheduled']) * 1000 for row in rows if row.get('drawn') is not None)
            if any(not math.isfinite(v) or v < 0 for v in durations):
                raise ValueError('Invalid character timing')
            values.append(durations)
        va, vb = values
        def metric(v, percentile):
            return f'{v[max(0, math.ceil(len(v)*percentile)-1)]:.2f}' if v else 'unavailable'
        lines.append(f'{lane:10} {len(va)}/{len(vb)} of {wa["count"]}    {metric(va,.95)}/{metric(vb,.95)}    {metric(va,1)}/{metric(vb,1)}')
        if len(va) != wa['count'] or len(vb) != wa['count']:
            lines.append('  INCOMPLETE: missing draws are excluded from percentiles; these numbers cannot establish improvement.')
    lines.append('Matched settings do not establish matched external load. Check window size, pointer position, visibility and concurrent activity. Repeat in reversed order before attributing a change to the patch.')
    return '\n'.join(lines)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('a', help='First retained profile')
    parser.add_argument('b', help='Second retained profile')
    args = parser.parse_args()
    print(compare(load(args.a), load(args.b)))
