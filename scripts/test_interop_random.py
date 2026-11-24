#!/usr/bin/env python3
"""Seeded independent pydlt records -> typed MoonBit reconstruction -> pydlt.

The fixture codec remains pydlt; this script defines values, never a second
wire-format implementation. The seed is fixed so regressions are reproducible.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import struct

import interop

SEED = 20261124


def identifier(rng: random.Random) -> str:
    return "".join(rng.choice('ABCD019_ ="') for _ in range(rng.randrange(5)))


def argument(rng: random.Random, choice: int):
    pydlt = interop.pydlt
    if choice == 0:
        return pydlt.ArgumentBool(bool(rng.getrandbits(1)))
    if choice in (1, 2):
        width = rng.choice((8, 16, 32, 64))
        value = rng.randrange(-(1 << (width - 1)), 1 << (width - 1)) if choice == 1 else rng.getrandbits(width)
        kind = getattr(pydlt, f"Argument{'SInt' if choice == 1 else 'UInt'}{width}")
        return kind(value)
    if choice in (3, 4):
        width = 32 if choice == 3 else 64
        while True:
            packed = rng.getrandbits(width).to_bytes(width // 8, "big")
            value = struct.unpack(">f" if width == 32 else ">d", packed)[0]
            if math.isfinite(value):
                return (pydlt.ArgumentFloat32 if width == 32 else pydlt.ArgumentFloat64)(value)
    if choice == 5:
        text = "".join(chr(rng.randrange(1, 128)) for _ in range(rng.randrange(32)))
        return pydlt.ArgumentString(text)
    if choice == 6:
        text = "".join(rng.choice("发动机温度🙂éΩ\ufeff\u2028") for _ in range(rng.randrange(24)))
        return pydlt.ArgumentString(text, is_utf8=True)
    return pydlt.ArgumentRaw(rng.randbytes(rng.randrange(40)))


def record(rng: random.Random, index: int, storage: bool):
    pydlt = interop.pydlt
    options = {
        "msb_first": index % 2 == 1,
        "message_counter": rng.randrange(256),
        "ecu_id": identifier(rng) if rng.getrandbits(1) else None,
        "session_id": rng.getrandbits(32) if rng.getrandbits(1) else None,
        "timestamp": rng.getrandbits(32) if rng.getrandbits(1) else None,
        "str_header": pydlt.StorageHeader(rng.getrandbits(32), rng.randrange(1000000), identifier(rng)) if storage else None,
    }
    if index % 4 == 3:
        return pydlt.DltMessage.create_non_verbose_message(
            rng.getrandbits(32), rng.randbytes(rng.randrange(48)), **options,
        )
    args = [argument(rng, (index + i) % 8) for i in range(index % 20)]
    return pydlt.DltMessage.create_verbose_message(
        args, pydlt.MessageType.DLT_TYPE_LOG,
        pydlt.MessageLogInfo(rng.randrange(1, 7)), identifier(rng), identifier(rng), **options,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=int, default=192)
    options = parser.parse_args()
    if options.cases < 1 or options.cases > 3000:
        parser.error("--cases must be 1..3000")
    cli = interop.build_cli()
    rng = random.Random(SEED)
    for index in range(options.cases):
        framing = ("storage", "network", "serial")[index % 3]
        message = record(rng, index, framing == "storage")
        wire = message.to_bytes()
        if framing == "serial":
            wire = b"DLS\x01" + wire
        expected = interop.oracle_decode(wire, framing)
        actual = interop.invoke(cli, "roundtrip", framing, wire.hex())
        context = f"seed={SEED} case={index} framing={framing}"
        interop.assert_equal(actual["message"], expected, f"typed values {context}")
        interop.assert_equal(actual["hex"], wire.hex(), f"typed rebuild exact bytes {context}")
        interop.assert_equal(interop.oracle_decode(bytes.fromhex(actual["hex"]), framing), expected,
                             f"independent reverse parse {context}")
    report = {"oracle": "pydlt==0.3.5", "seed": SEED, "cases": options.cases,
              "result": "PASS", "coverage": ["typed decode/rebuild", "both payload endians",
              "three framing forms", "empty verbose payload", "finite IEEE normal/subnormal values",
              "integer samples", "ASCII controls", "Unicode and BOM content", "opaque raw bytes"]}
    target = interop.ROOT / "work" / "validation" / "random_interop.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {options.cases} seeded independent records and exact typed reconstruction (seed={SEED})")


if __name__ == "__main__":
    main()
