#!/usr/bin/env python3
"""Exercise real range I/O through the Node adapter and MoonBit codec."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'scripts' / 'moondlt.mjs'
FIXTURE = ROOT / 'fixtures' / 'pydlt-0.3.5-storage.dlt'


def invoke(*arguments: str, success: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(['node', str(CLI), *map(str, arguments)], cwd=ROOT,
                            capture_output=True, encoding='utf-8')
    if (result.returncode == 0) != success:
        raise AssertionError(f'Unexpected CLI status {result.returncode}: {result.stdout}\n{result.stderr}')
    return result


def main() -> None:
    golden = json.loads((ROOT / 'fixtures' / 'pydlt-0.3.5-golden.json').read_text(encoding='utf-8'))
    records = [case for case in golden['cases'] if case['framing'] == 'storage']
    inspected = json.loads(invoke('inspect', FIXTURE, '--limit', '2').stdout)
    assert inspected['scanned'] == '18' and inspected['matched'] == '18'
    assert inspected['shown'] == 2 and inspected['metadata_only']
    assert inspected['largest_read_bytes'] <= 22  # prefix20 + optional header22, never payload
    assert int(inspected['header_bytes_read']) < FIXTURE.stat().st_size
    expected = b''.join(bytes.fromhex(case['hex']) for case in records
                        if case['expected']['extended'] is not None
                        and case['expected']['extended']['application'] == 'APP')
    out = ROOT / 'out'
    out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='file-cli-', dir=out) as temporary:
        target = Path(temporary) / 'selected.dlt'
        extracted = json.loads(invoke('extract', FIXTURE, target, '--filter', 'apid == "APP"').stdout)
        assert target.read_bytes() == expected
        assert extracted['written_bytes'] == str(len(expected))
        matched = sum(case['expected']['extended'] is not None for case in records)
        assert extracted['matched'] == str(matched)
        original = target.read_bytes()
        invoke('extract', FIXTURE, target, success=False)
        assert target.read_bytes() == original  # exclusive output never overwritten
        invoke('extract', FIXTURE, FIXTURE, success=False)
        bad_target = Path(temporary) / 'bad.dlt'
        invoke('extract', FIXTURE, bad_target, '--filter', 'bogus == 1', success=False)
        assert not bad_target.exists()  # failed new output cleaned
        invoke('inspect', FIXTURE, '--filter', 'apid = "APP"', success=False)
        invoke('inspect', FIXTURE, '--limit', '10001', success=False)
        truncated = Path(temporary) / 'truncated.dlt'
        truncated.write_bytes(FIXTURE.read_bytes()[:-1])
        invoke('inspect', truncated, success=False)
        partial = Path(temporary) / 'partial-extraction.dlt'
        invoke('extract', truncated, partial, success=False)
        assert not partial.exists()  # failure after earlier writes cannot leave a partial recording
        case_input = Path(temporary) / 'Case.dlt'
        case_output = Path(temporary) / 'case.dlt'
        case_input.write_bytes(FIXTURE.read_bytes())
        if not case_output.exists():  # a case-sensitive filesystem permits these distinct names
            invoke('extract', case_input, case_output)
            assert case_output.read_bytes() == case_input.read_bytes()
    print('PASS: actual file inspect/extract, exact bytes, bounded reads, errors and no-overwrite')


if __name__ == '__main__':
    main()
