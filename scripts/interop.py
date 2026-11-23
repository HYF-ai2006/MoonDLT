#!/usr/bin/env python3
"""Bidirectional MoonDLT / pydlt 0.3.5 interoperability, without a second codec.

Install the optional independent oracle in this project's ignored work/ directory:
  python -m pip install --target work/pydeps pydlt==0.3.5
Run:
  python scripts/interop.py
Regenerate committed golden fixtures only after reviewing changes:
  python scripts/interop.py --generate-fixtures
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "work" / "pydeps"))
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")

try:
    import pydlt
except ImportError as exc:
    raise SystemExit(
        "Install the independent oracle: python -m pip install "
        "--target work/pydeps pydlt==0.3.5"
    ) from exc

ORACLE_VERSION = importlib.metadata.version("pydlt")
if ORACLE_VERSION != "0.3.5":
    raise SystemExit(f"Expected pydlt==0.3.5; got {ORACLE_VERSION}")


def rich_arguments() -> list:
    return [
        pydlt.ArgumentBool(True), pydlt.ArgumentBool(False),
        pydlt.ArgumentSInt8(-128), pydlt.ArgumentSInt16(-32768),
        pydlt.ArgumentSInt32(-2147483648), pydlt.ArgumentSInt64(-9223372036854775808),
        pydlt.ArgumentUInt8(255), pydlt.ArgumentUInt16(65535),
        pydlt.ArgumentUInt32(4294967295), pydlt.ArgumentUInt64(18446744073709551615),
        pydlt.ArgumentFloat32(-13.25), pydlt.ArgumentFloat64(0.125),
        pydlt.ArgumentString("temperature"),
        pydlt.ArgumentString("发动机🙂", is_utf8=True),
        pydlt.ArgumentString(""),
        pydlt.ArgumentRaw(bytes.fromhex("00ff444c5401")), pydlt.ArgumentRaw(b""),
    ]


def oracle_message(case_id: int, with_storage: bool) -> pydlt.DltMessage:
    """Same public vector values as MoonBit; serialization belongs to pydlt."""
    flags = 15 if case_id < 2 else case_id - 2
    options = {
        "msb_first": case_id % 2 != 0,
        "message_counter": 255 if case_id == 1 else case_id,
        "ecu_id": "ECU2" if flags & 1 else None,
        "session_id": 4294967295 if flags & 2 else None,
        "timestamp": 305419896 if flags & 4 else None,
        "str_header": pydlt.StorageHeader(1700000000, 123456, "ECU1")
        if with_storage else None,
    }
    if flags & 8:
        arguments = rich_arguments() if case_id < 2 else [
            pydlt.ArgumentSInt32(-42),
            pydlt.ArgumentString("header-combination"),
        ]
        return pydlt.DltMessage.create_verbose_message(
            arguments,
            pydlt.MessageType.DLT_TYPE_LOG,
            pydlt.MessageLogInfo.DLT_LOG_INFO,
            "APP", "CTX1", **options,
        )
    return pydlt.DltMessage.create_non_verbose_message(
        0x12345678, bytes.fromhex("00ff7f"), **options,
    )


NUMERIC_ARGUMENTS = {
    pydlt.ArgumentSInt8: ("signed", 8),
    pydlt.ArgumentSInt16: ("signed", 16),
    pydlt.ArgumentSInt32: ("signed", 32),
    pydlt.ArgumentSInt64: ("signed", 64),
    pydlt.ArgumentUInt8: ("unsigned", 8),
    pydlt.ArgumentUInt16: ("unsigned", 16),
    pydlt.ArgumentUInt32: ("unsigned", 32),
    pydlt.ArgumentUInt64: ("unsigned", 64),
    pydlt.ArgumentFloat32: ("float", 32),
    pydlt.ArgumentFloat64: ("float", 64),
}


def argument_json(argument) -> dict:
    if isinstance(argument, pydlt.ArgumentBool):
        return {"kind": "bool", "value": argument.data}
    if isinstance(argument, pydlt.ArgumentString):
        return {
            "kind": "string",
            "encoding": "utf8" if argument.is_utf8 else "ascii",
            "value": argument.data,
        }
    if isinstance(argument, pydlt.ArgumentRaw):
        return {"kind": "raw", "value": argument.data.hex()}
    kind, width = NUMERIC_ARGUMENTS[type(argument)]
    return {"kind": kind, "width": width,
            "value": argument.data if kind == "float" else str(argument.data)}


def canonical_message(message: pydlt.DltMessage) -> dict:
    header = message.std_header
    extended = message.ext_header
    storage = message.str_header
    return {
        "storage": None if storage is None else {
            "seconds": str(storage.seconds),
            "microseconds": str(storage.microseconds), "ecu": storage.ecu_id,
        },
        "endian": "big" if header.msb_first else "little",
        "counter": header.message_counter,
        "ecu": header.ecu_id,
        "session": None if header.session_id is None else str(header.session_id),
        "timestamp": None if header.timestamp is None else str(header.timestamp),
        "extended": None if extended is None else {
            "verbose": extended.verbose,
            "message_type": int(extended.message_type),
            "subtype": int(extended.message_type_info),
            "argument_count": extended.number_of_arguments,
            "application": extended.application_id, "context": extended.context_id,
        },
        "payload_hex": "" if message.payload is None else
        message.payload.to_bytes(header.msb_first).hex(),
        "arguments": [argument_json(argument)
                      for argument in message.verbose_payload.arguments]
        if extended is not None and extended.verbose else None,
    }


def wire_bytes(case_id: int, framing: str) -> bytes:
    message = oracle_message(case_id, framing == "storage")
    raw = message.to_bytes()
    return b"DLS\x01" + raw if framing == "serial" else raw


def oracle_decode(raw: bytes, framing: str) -> dict:
    if framing == "serial":
        assert raw[:4] == b"DLS\x01", "serial marker mismatch"
        raw = raw[4:]
    return canonical_message(
        pydlt.DltMessage.create_from_bytes(raw, framing == "storage")
    )


def golden_document() -> dict:
    cases = []
    for case_id in range(18):
        for framing in ("storage", "network", "serial"):
            raw = wire_bytes(case_id, framing)
            cases.append({
                "case": case_id, "framing": framing,
                "hex": raw.hex(), "sha256": hashlib.sha256(raw).hexdigest(),
                "expected": oracle_decode(raw, framing),
            })
    return {"schema": "moondlt-interop-v1", "producer": "pydlt",
            "producer_version": ORACLE_VERSION, "cases": cases}


def assert_equal(actual, expected, context: str) -> None:
    if actual != expected:
        raise AssertionError(
            f"{context}\nEXPECTED: {json.dumps(expected, ensure_ascii=False, sort_keys=True)}"
            f"\nACTUAL: {json.dumps(actual, ensure_ascii=False, sort_keys=True)}"
        )


def build_cli() -> Path:
    subprocess.run(["moon", "build", "cmd/interop", "--target", "js", "--deny-warn"],
                   cwd=ROOT, check=True)
    expected = ROOT / "_build" / "js" / "debug" / "build" / "cmd" / "interop" / "interop.js"
    if expected.is_file():
        return expected
    candidates = list((ROOT / "_build" / "js" / "debug").glob("**/cmd/interop/interop.js"))
    if not candidates:
        candidates = list((ROOT / "_build" / "js" / "debug").glob("**/cmd/interop/*.js"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one compiled interop entry point; got {candidates}")
    return candidates[0]


def invoke(cli: Path, operation: str, framing: str, value: str) -> dict:
    result = subprocess.run(["node", str(cli), operation, framing, value],
                            cwd=ROOT, check=True, capture_output=True,
                            encoding="utf-8")
    try:
        answer = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"Invalid MoonBit CLI output: {result.stdout!r}") from exc
    if "error" in answer:
        raise AssertionError(f"MoonBit {operation}: {answer['error']}")
    return answer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate-fixtures", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true",
                        help="Check deterministic oracle fixtures without compiling MoonBit")
    arguments = parser.parse_args()
    document = golden_document()
    golden_path = ROOT / "fixtures" / "pydlt-0.3.5-golden.json"
    concatenated = b"".join(wire_bytes(i, "storage") for i in range(18))
    if arguments.generate_fixtures:
        golden_path.parent.mkdir(parents=True, exist_ok=True)
        golden_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8", newline="\n")
        (golden_path.parent / "pydlt-0.3.5-storage.dlt").write_bytes(concatenated)
        print(f"Generated {len(document['cases'])} independent golden vectors")
        return
    assert_equal(json.loads(golden_path.read_text(encoding="utf-8")), document,
                 "Committed fixtures differ from pinned pydlt oracle")
    assert_equal((golden_path.parent / "pydlt-0.3.5-storage.dlt").read_bytes().hex(),
                 concatenated.hex(), "Concatenated .dlt fixture differs")
    if arguments.check_fixtures:
        print(f"PASS: {len(document['cases'])} deterministic pydlt golden vectors")
        return
    cli = build_cli()
    for vector in document["cases"]:
        framing = vector["framing"]
        context = f"case={vector['case']} framing={framing}"
        # Direction one: independent serializer -> MoonBit parser, typed values.
        decoded = invoke(cli, "decode", framing, vector["hex"])
        assert_equal(decoded, vector["expected"], f"pydlt -> MoonBit {context}")
        # Direction two: MoonBit serializer -> independent parser, typed values.
        encoded = invoke(cli, "encode", framing, str(vector["case"]))
        assert_equal(encoded["hex"], vector["hex"], f"wire bytes {context}")
        independent = oracle_decode(bytes.fromhex(encoded["hex"]), framing)
        assert_equal(independent, vector["expected"], f"MoonBit -> pydlt {context}")
    report = {
        "oracle": f"pydlt=={ORACLE_VERSION}",
        "vectors": len(document["cases"]),
        "directions": ["pydlt -> MoonBit", "MoonBit -> pydlt"],
        "checks": ["all header optional-field combinations", "little/big endian",
                   "storage/network/serial framing", "all supported scalar types",
                   "signed64 minimum", "uint64 maximum", "ASCII/UTF8",
                   "empty string/raw", "canonical typed values", "exact wire bytes"],
        "result": "PASS",
        "limitations": "Common DLT v1 profile only; not complete AUTOSAR conformance",
    }
    output = ROOT / "work" / "validation" / "interop.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {report['vectors']} vectors, two independent directions, exact bytes")


if __name__ == "__main__":
    main()
