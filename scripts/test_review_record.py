"""Exercise real Storage files through the public CLI, optionally with dlt_parse."""
from __future__ import annotations

import argparse
from itertools import product
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures" / "review"
COUNTER = (1 << 96) + 1


def payload(big: bool, text: str = "boot") -> bytes:
    order = ">" if big else "<"
    encoded = text.encode("ascii") + b"\0"
    return (struct.pack(order + "IHIH", 0x4000, 2, 0x2000, len(encoded))
            + encoded + struct.pack(order + "I", 0x45)
            + COUNTER.to_bytes(16, "big" if big else "little"))


def storage(body: bytes, big: bool, count: int = 1) -> bytes:
    return (b"DLT\x01" + struct.pack("<II", 7, 123) + b"ECU1"
            + struct.pack(">BBHBB", 0x23 if big else 0x21, 0, 14 + len(body), 0x41, count)
            + b"APP1CORE" + body)


def cli(*args: object, success: bool = True) -> None:
    run = subprocess.run(["node", str(ROOT / "scripts/moondlt.mjs"), *map(str, args)],
                         cwd=ROOT, capture_output=True, encoding="utf8")
    if (run.returncode == 0) != success:
        raise AssertionError(run.stdout + run.stderr)


def rust(op: str, path: Path) -> None:
    subprocess.run(["cargo", "run", "--quiet", "--locked", "--manifest-path",
                    str(ROOT / "tools/review-oracle/Cargo.toml"), "--", op, str(path)],
                   cwd=ROOT, env={**os.environ, "CARGO_TARGET_DIR": str(ROOT / "work/cargo-target")}, check=True)


def save_json(path: Path, doc: dict) -> None:
    path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf8")


def check_json_limits(directory: Path) -> None:
    # Fit 128 structures and 5,000 leaves in a wire record. Its pretty JSON
    # exceeds the editable model limit because each leaf is indented 128 levels.
    top = struct.pack("<IH", 0x4000, 1) * 127
    leaf = struct.pack("<IB", 0x11, 1)
    body = top + struct.pack("<IH", 0x4000, 5000) + leaf * 5000
    record, model = directory / "deep.dlt", directory / "deep.json"
    record.write_bytes(storage(body, False))
    cli("decode", record, model)
    assert model.stat().st_size <= 8 * 1024 * 1024
    rebuilt = directory / "rebuilt.dlt"
    cli("encode", model, rebuilt)
    assert rebuilt.read_bytes() == record.read_bytes()

    duplicate = directory / "duplicate.json"
    doc = json.loads(model.read_text(encoding="utf8"))
    original = json.dumps(doc)
    duplicate.write_text(original.replace('"format":', '"format":"wrong","format":', 1), encoding="utf8")
    bad_output = directory / "duplicate.dlt"
    cli("encode", duplicate, bad_output, success=False)
    assert not bad_output.exists()


def check_type_combinations(directory: Path) -> None:
    for big, endian in [(False, "little"), (True, "big")]:
        body = bytearray()
        parameters = []

        def uint(value: int, width: int) -> bytes:
            return value.to_bytes(width, endian)

        def string(text: str) -> tuple[bytes, bytes]:
            value = text.encode("utf8") + b"\0"
            return uint(len(value), 2), value

        # Table 5-13 and the numeric payload layouts in §§5.1.3.5–7,9.
        for name, bit, widths in [
            ("bool", 0x10, (8,)),
            ("signed", 0x20, (8, 16, 32, 64, 128)),
            ("unsigned", 0x40, (8, 16, 32, 64, 128)),
            ("float", 0x80, (16, 32, 64, 128)),
        ]:
            fixed = (False, True) if name in {"signed", "unsigned"} else (False,)
            for width, array, variable, scaling in product(widths, (False, True), (False, True), fixed):
                type_info = bit | ((width // 8).bit_length())
                type_info |= (array << 8) | (variable << 11) | (scaling << 12)
                body += uint(type_info, 4)
                dimensions = [2, 3] if array else []
                if array:
                    body += uint(2, 2) + uint(2, 2) + uint(3, 2)
                info = None
                if variable:
                    nl, nv = string("name")
                    if array or name != "bool":
                        ul, uv = string("unit")
                        body += nl + ul + nv + uv
                        info = {"name": "name", "unit": "unit"}
                    else:
                        body += nl + nv
                        info = {"name": "name", "unit": None}
                fixed_info = None
                if scaling:
                    offset_width = max(32, width) // 8
                    offset = -(1 << (offset_width * 8 - 1)) + 4
                    body += uint(0xBF000000, 4) + offset.to_bytes(offset_width, endian, signed=True)
                    fixed_info = {"quantization_bits": "bf000000", "offset": str(offset)}
                values = []
                for i in range(6 if array else 1):
                    if name == "bool":
                        n = i % 2
                        values.append(bool(n))
                    elif name == "signed":
                        n = -(1 << (width - 1)) + i
                        values.append(str(n))
                    elif name == "unsigned":
                        n = (1 << width) - 1 - i
                        values.append(str(n))
                    else:
                        n = (1 << width) - 1 - i
                        values.append(f"{n:0{width // 4}x}")
                    body += n.to_bytes(width // 8, endian, signed=name == "signed")
                parameters.append({"type": name, "width": width, "dimensions": dimensions,
                                   "variable": info, "scaling": fixed_info, "values": values})

        # STRG and TRAI are distinct argument types; SCOD applies to both.
        for coding, text in [("ascii", "A"), ("utf8", "配🙂")]:
            scod = 0x8000 if coding == "utf8" else 0
            tl, tv = string(text)
            for variable in [False, True]:
                body += uint(0x200 | scod | (variable << 11), 4) + tl
                if variable:
                    nl, nv = string("name")
                    body += nl + nv
                body += tv
                parameters.append({"type": "text", "encoding": coding, "text": text,
                                   "name": "name" if variable else None})
            body += uint(0x2000 | scod, 4) + tl + tv
            parameters.append({"type": "trace-info", "encoding": coding, "text": text})

        for variable in [False, True]:
            nl, nv = string("name")
            body += uint(0x400 | (variable << 11), 4) + uint(2, 2)
            if variable:
                body += nl + nv
            body += b"\0\xff"
            parameters.append({"type": "raw", "name": "name" if variable else None, "hex": "00ff"})

            body += uint(0x4000 | (variable << 11), 4) + uint(1, 2)
            if variable:
                body += nl + nv
            tl, tv = string("child")
            body += uint(0x2000, 4) + tl + tv
            parameters.append({"type": "struct", "name": "name" if variable else None,
                               "members": [{"type": "trace-info", "encoding": "ascii", "text": "child"}]})

        assert len(parameters) == 110
        binary = storage(body, big, len(parameters))
        record, model = directory / "types.dlt", directory / "types.json"
        record.write_bytes(binary)
        output = directory / f"types-{endian}.dlt"
        cli("decode", record, model)
        parsed = json.loads(model.read_text(encoding="utf8"))
        assert parsed["parameters"] == parameters
        cli("encode", model, output)
        assert output.read_bytes() == binary
        model.unlink()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--generate-fixtures", action="store_true")
    p.add_argument("--rust", action="store_true")
    options = p.parse_args()
    if options.generate_fixtures:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        for big, label in [(False, "le"), (True, "be")]:
            (FIXTURES / f"fault-{label}.dlt").write_bytes(storage(payload(big), big))
        return
    work = ROOT / "work"
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=work) as tmp:
        d = Path(tmp)
        for big, label in [(False, "le"), (True, "be")]:
            fixture = FIXTURES / f"fault-{label}.dlt"
            model, edited = d / f"{label}.json", d / f"{label}.dlt"
            assert fixture.read_bytes() == storage(payload(big), big)
            cli("decode", fixture, model)
            doc = json.loads(model.read_text(encoding="utf8"))
            assert "payload_hex" not in doc
            members = doc["parameters"][0]["members"]
            assert doc["header"]["extended"]["count"] == 1
            assert members[0] == {"type": "trace-info", "encoding": "ascii", "text": "boot"}
            assert (members[1]["type"], members[1]["width"], members[1]["values"]) == ("unsigned", 128, [str(COUNTER)])
            members[0]["text"] = "ready"
            save_json(model, doc)
            cli("encode", model, edited)
            assert edited.read_bytes() == storage(payload(big, "ready"), big)
            cli("encode", model, edited, success=False)
            assert edited.read_bytes() == storage(payload(big, "ready"), big)
            members[1]["values"] = [str(1 << 128)]
            save_json(model, doc)
            invalid = d / f"invalid-{label}.dlt"
            cli("encode", model, invalid, success=False)
            assert not invalid.exists()
        check_json_limits(d)
        check_type_combinations(d)
        if options.rust:
            bridge = d / "bridge.bin"
            rust("emit", bridge)
            assert bridge.read_bytes() == payload(False)
            # The checked-in input decoded above matches this independent emitter.
            bridge.write_bytes((d / "le.dlt").read_bytes()[30:])
            rust("check", bridge)
            rust("wide", bridge)
            wide = d / "wide.dlt"
            model = d / "wide.json"
            wide.write_bytes(storage(bridge.read_bytes(), False, 3))
            cli("decode", wide, model)
            doc = json.loads(model.read_text(encoding="utf8"))
            wideint, half, quad = doc["parameters"]
            assert wideint["values"] == [str(-(1 << 127))]
            assert wideint["scaling"] == {"quantization_bits":"3f000000","offset":str(-(1 << 96))}
            assert half["values"] == ["8000"] and quad["values"] == ["3fff0000000000000000000000000001"]
            wideint["values"][0] = str(-(1 << 127) + 1)
            save_json(model, doc)
            output = d / "wide-edited.dlt"
            cli("encode", model, output)
            bridge.write_bytes(output.read_bytes()[30:])
            rust("wide-check", bridge)
    print("PASS: Storage LE/BE 37 to 38 bytes, typed JSON edit, 220 Type Info cases; "
          + ("independent Rust STRU/TRAI/U128/I128/FIXP/F16/F128 checks passed" if options.rust else "standard-derived vectors"))


if __name__ == "__main__":
    main()
