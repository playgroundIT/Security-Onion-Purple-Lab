#!/usr/bin/env python3
"""Conservative Linux flag check for the SO 3.3 x86-64-v3 requirement."""
import sys
from pathlib import Path


def check(cpuinfo):
    required = {
        'lm', 'cmov', 'cx8', 'fxsr', 'mmx', 'sse', 'sse2',
        'cx16', 'lahf_lm', 'popcnt', 'sse4_1', 'sse4_2', 'ssse3',
        'avx', 'avx2', 'bmi1', 'bmi2', 'f16c', 'fma', 'movbe', 'xsave',
    }
    cpus = [set(line.split(':', 1)[1].split()) for line in cpuinfo.splitlines()
            if line.startswith('flags')]
    if not cpus:
        raise SystemExit('CPU preflight: no x86 flags found')
    for index, flags in enumerate(cpus):
        missing = required - flags
        if not flags & {'pni', 'sse3'}:
            missing.add('sse3/pni')
        if not flags & {'abm', 'lzcnt'}:
            missing.add('lzcnt/abm')
        if missing:
            raise SystemExit(f'CPU preflight: CPU {index} lacks x86-64-v3 features: '
                             + ', '.join(sorted(missing)))


if __name__ == '__main__':
    check(Path(sys.argv[1] if len(sys.argv) > 1 else '/proc/cpuinfo').read_text())
    print('CPU OK: Linux exposes x86-64-v3 features; VM CPU must remain host.')
