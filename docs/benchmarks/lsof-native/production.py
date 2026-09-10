"""Run ProductionBenchmark under baseline and +800 loopback sockets.

Usage: python3 production.py /absolute/path/to/production-benchmark /output/directory
Output contains aggregate timings/counts, not process arguments or endpoints.
"""
import csv
import json
import math
import platform
import resource
import statistics
import subprocess
import sys
from pathlib import Path
import compare


def main():
    executable = str(Path(sys.argv[1]).resolve())
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)
    report = dict(machine=platform.machine(), os=platform.mac_ver()[0], samples_per_backend=30)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, 4096), hard), hard))
    try:
        for stage in ['baseline', 'loaded']:
            if stage == 'loaded':
                for _ in range(200):
                    listener = compare.make(compare.socket.AF_INET, compare.socket.SOCK_STREAM)
                    listener.listen()
                    client = compare.make(compare.socket.AF_INET, compare.socket.SOCK_STREAM)
                    client.connect(listener.getsockname())
                    accepted, _ = listener.accept()
                    compare.fixtures.append(accepted)
                for _ in range(200):
                    compare.make(compare.socket.AF_INET, compare.socket.SOCK_DGRAM)
            path = output_dir / f'production-{stage}.csv'
            with path.open('w') as output:
                result = subprocess.run([executable], stdout=output, stderr=subprocess.PIPE,
                                        text=True, check=True, timeout=60)
            with path.open() as source:
                rows = list(csv.DictReader(source))
            report[stage] = dict(coverage=result.stderr.strip(), extra_fixture_sockets=len(compare.fixtures))
            for backend in ['native', 'lsof']:
                values = [row for row in rows if row['backend'] == backend]
                metrics = {}
                for field in ['total_ms', 'collection_ms', 'enrichment_ms', 'cpu_ms', 'records']:
                    numbers = sorted(float(row[field]) for row in values)
                    metrics[field] = dict(p50=round(statistics.median(numbers), 3),
                                          p95=round(numbers[math.ceil(len(numbers) * .95) - 1], 3))
                metrics['partial_snapshots'] = sum(row['partial'] == 'true' for row in values)
                metrics['fallback_snapshots'] = sum(row['source'] == 'lsofFallback' for row in values)
                report[stage][backend] = metrics
    finally:
        for sock in compare.fixtures:
            sock.close()
    (output_dir / 'production-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
