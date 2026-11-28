"""Reconstruct a packed R19-11 capture from independently assembled bytes."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

from import_arxml import CatalogError, load_catalog

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "fixtures" / "review"
XML = FIXTURE / "arxml-dlt.arxml"
CAPTURE = FIXTURE / "arxml-power.dlt"


def packet(*, big=False, extended=False, ecu=b"PWR1", apid=b"POWR",
           ctid=b"VOLT", count=0, message_id=0x12345678, truncate=False,
           trailing=False, subtype=3, storage=True):
    order = "big" if big else "little"
    payload = struct.pack(">IH" if big else "<IH", message_id, 3312)
    payload += ((1 << 96) + 1).to_bytes(16, order)
    if truncate:
        payload = payload[:-1]
    if trailing:
        payload += b"\x00"
    extra = struct.pack("BB", subtype << 4, count) + apid + ctid if extended else b""
    header = struct.pack(">BBH", 0x20 | (2 if big else 0) | int(extended), 4,
                         4 + len(extra) + len(payload))
    prefix = b"DLT\x01" + struct.pack("<II", 42, 19) + ecu if storage else b""
    return prefix + header + extra + payload


def run(*command, success=True):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, check=False, encoding="utf-8")
    if (result.returncode == 0) != success:
        raise AssertionError((result.returncode, result.stdout, result.stderr))
    return result


def main():
    if sys.argv[1:] == ["--generate-fixture"]:
        CAPTURE.write_bytes(packet())
        return
    assert CAPTURE.read_bytes() == packet()
    work = ROOT / "work"
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=work) as temp:
        base = Path(temp)
        meta = base / "catalog.json"
        run(sys.executable, "scripts/import_arxml.py", str(XML), "-o", str(meta))
        original = json.loads(meta.read_text(encoding="utf-8"))
        other = base / "generated.dlt"

        def decode(source: Path, framing="storage", error=None):
            result = run("node", "scripts/moondlt-arxml.mjs", str(meta), str(source), framing,
                         success=error is None)
            if error is not None:
                assert error in result.stderr, result.stderr
                return None
            return json.loads(result.stdout)

        values = decode(CAPTURE)
        assert values["message_id"] == "305419896"
        assert (values["ecu"], values["application"], values["context"]) == ("PWR1", "POWR", "VOLT")
        assert (values["message_type"], values["subtype"]) == (0, 3)
        assert (values["source_file"], values["source_line"]) == ("power_monitor.c", "27")
        assert (values["argument_count"], values["dynamic_argument_count"]) == (3, 2)
        first, second, wide = values["arguments"]
        assert (first["static"], first["value"]["text"]) == (True, "Voltage dropped")
        assert (second["name"], second["unit_ref"], second["value"]["values"]) == (
            "millivolts", "/Units/mV", ["3312"])
        assert (wide["value"]["width"], wide["value"]["values"]) == (128, [str((1 << 96) + 1)])
        assert wide["unit_ref"] == "/Units/Events"
        assert wide["value"]["scaling"] == {
            "quantization_bits": "3f000000", "offset": str(-(1 << 96)),
        }
        other.write_bytes(packet(big=True, extended=True))
        assert decode(other) == values
        for args, message in [
            ({"message_id": 57}, "unknown ARXML message ID"),
            ({"ecu": b"FAIL"}, "no ARXML binding matches"),
            ({"extended": True, "apid": b"FAIL"}, "no ARXML binding matches"),
            ({"extended": True, "subtype": 4}, "MSIN differs"),
            ({"extended": True, "count": 1}, "NOAR must be zero"),
            ({"truncate": True}, "truncated DLT"),
            ({"trailing": True}, "trailing bytes"),
        ]:
            other.write_bytes(packet(**args))
            decode(other, error=message)
        ambiguous = copy.deepcopy(original)
        added = copy.deepcopy(ambiguous["messages"][0])
        added["context"] = "CURR"
        ambiguous["messages"].append(added)
        meta.write_text(json.dumps(ambiguous), encoding="utf-8")
        decode(CAPTURE, error="ambiguous ARXML message binding")
        other.write_bytes(packet(big=True, extended=True))
        assert decode(other) == values
        assert load_catalog([XML]) == original
        meta.write_text('{"format":"other",' + json.dumps(original)[1:], encoding="utf-8")
        decode(CAPTURE, error="malformed ARXML catalogue JSON")
        unsupported_scaling = copy.deepcopy(original)
        unsupported_scaling["messages"][0]["fields"][2]["scaling"]["quantization_bits"] = "7f800000"
        meta.write_text(json.dumps(unsupported_scaling), encoding="utf-8")
        decode(CAPTURE, error="invalid ARXML fixed-point parameters")
        # An independent document may own a base type while another defines the
        # ECU or message. A broken reference cannot fall back to a guessed type.
        bad_xml = base / "broken.arxml"
        source = XML.read_text(encoding="utf-8")
        for changed, error in [
            (source.replace("/Diagnostics/Logs/VoltageDrop", "/Diagnostics/Logs/Unknown"),
             "unresolved DLT-MESSAGE reference"),
            (source.replace("/Diagnostics/WideCounter", "/SomeOtherPackage/WideCounter"),
             "unresolved SW-BASE-TYPE"),
            (source.replace("<LENGTH>16</LENGTH>", "<LENGTH>24</LENGTH>"),
             "conflicts with base type"),
            (source.replace("/Diagnostics/CounterOrigin", "/Diagnostics/Missing"),
             "unresolved COMPU-METHOD reference"),
            (source.replace("<V>2</V></COMPU-DENOMINATOR>", "<V>10</V></COMPU-DENOMINATOR>")
             .replace("-158456325028528675187087900672", "0"),
             "inexact binary32 COMPU-METHOD quantization"),
            (source.replace("-158456325028528675187087900672", "1"),
             "offset at /Diagnostics/CounterOrigin does not fit"),
            (source.replace("<V>2</V></COMPU-DENOMINATOR>", "<V>0</V></COMPU-DENOMINATOR>"),
             "zero COMPU-DENOMINATOR"),
            (source.replace("<AUTOSAR ", "<!DOCTYPE AUTOSAR>\n<AUTOSAR ", 1),
             "DOCTYPE is not allowed"),
        ]:
            bad_xml.write_text(changed, encoding="utf-8")
            try:
                load_catalog([bad_xml])
            except CatalogError as exc:
                assert error in str(exc), str(exc)
            else:
                raise AssertionError(f"expected {error}")
    print("ARXML PASS: channel and references, metadata without UEH, LE/BE packed data, exact 128-bit scalar/FIXP, missing/ambiguous/corrupt input")


if __name__ == "__main__":
    main()
