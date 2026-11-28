"""Resolve AUTOSAR Classic DLT metadata into a MoonDLT catalogue.

The XML is read as local text. DTDs, external resources, and XInclude are not
processed. Only the R19-11 DLT metadata used to bind and lay out messages is imported.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from xml.etree import ElementTree as ET

NS = "{http://autosar.org/schema/r4.0}"
MAX_XML_BYTES = 8 * 1024 * 1024
NAMED_NODES = {
    "AR-PACKAGE", "DLT-MESSAGE-COLLECTION-SET", "DLT-MESSAGE", "SW-BASE-TYPE",
    "UNIT", "ECU-INSTANCE", "DLT-LOG-CHANNEL",
}
ENCODING_KIND = {
    "2C": "signed", "NONE": "unsigned", "IEEE754": "float", "BOOLEAN": "bool",
    "ASCII": "ascii", "UTF-8": "utf8", "UTF8": "utf8", "OPAQUE": "raw",
}
MESSAGE_TYPES = {
    prefix + value: (message_type, i)
    for message_type, prefix, values in [
        (0, "DLT_LOG_", ("FATAL", "ERROR", "WARN", "INFO", "DEBUG", "VERBOSE")),
        (1, "DLT_TRACE_", ("VARIABLE", "FUNCTION_IN", "FUNCTION_OUT", "STATE", "VFB")),
        (2, "DLT_NW_TRACE_", ("IPC", "CAN", "FLEXRAY", "MOST", "ETHERNET", "SOMEIP")),
    ]
    for i, value in enumerate(values, start=1)
}


class CatalogError(ValueError):
    pass


class DltTreeBuilder(ET.TreeBuilder):
    def doctype(self, _name: str, _public_id: str, _system_id: str) -> None:
        raise CatalogError("DOCTYPE is not allowed in a DLT description")


def text(node: ET.Element, tag: str, *, required: bool = True) -> str | None:
    children = node.findall(NS + tag)
    if len(children) > 1:
        raise CatalogError(f"repeated {tag} in {node.tag}")
    if not children:
        if required:
            raise CatalogError(f"missing {tag} in {node.tag}")
        return None
    child = children[0]
    if len(child):
        raise CatalogError(f"expected leaf text in {tag}")
    value = (child.text or "").strip()
    if required and not value:
        raise CatalogError(f"empty {tag} in {node.tag}")
    return value or None


def uint(value: str, tag: str, maximum: int) -> int:
    if not re.fullmatch(r"[0-9]{1,10}|0[xX][0-9a-fA-F]{1,8}", value):
        raise CatalogError(f"invalid unsigned value in {tag}")
    n = int(value, 16 if value.lower().startswith("0x") else 10)
    if n > maximum:
        raise CatalogError(f"{tag} is outside its supported range")
    return n


def validate_id(value: str, tag: str) -> str:
    if not 1 <= len(value) <= 4 or any(not 32 <= ord(c) <= 126 for c in value):
        raise CatalogError(f"{tag} must be one to four printable ASCII characters")
    return value


def path_ref(value: str, tag: str) -> str:
    if not value.startswith("/") or any(
        not part or part in (".", "..") or any(c.isspace() for c in part)
        for part in value[1:].split("/")
    ):
        raise CatalogError(f"expected an absolute AUTOSAR reference in {tag}")
    return value


def read_documents(sources: list[Path]) -> list[ET.Element]:
    if not 1 <= len(sources) <= 64:
        raise CatalogError("one to 64 ARXML documents are required")
    roots = []
    remaining = MAX_XML_BYTES
    for path in sources:
        with path.open("rb") as stream:
            data = stream.read(remaining + 1)
        remaining -= len(data)
        if remaining < 0:
            raise CatalogError("combined ARXML input exceeds 8 MiB")
        root = ET.fromstring(data, parser=ET.XMLParser(target=DltTreeBuilder()))
        if root.tag != NS + "AUTOSAR":
            raise CatalogError("expected an AUTOSAR Classic r4.0 document")
        roots.append(root)
    return roots


def index_objects(roots: list[ET.Element]) -> dict[str, ET.Element]:
    objects: dict[str, ET.Element] = {}
    stack = [(root, "", 0) for root in roots]
    while stack:
        node, prefix, depth = stack.pop()
        if depth > 128:
            raise CatalogError("ARXML nesting exceeds 128 elements")
        if not isinstance(node.tag, str) or not node.tag.startswith(NS):
            continue
        local = node.tag.removeprefix(NS)
        if local in NAMED_NODES:
            name = text(node, "SHORT-NAME")
            assert name is not None
            path = path_ref(prefix + "/" + name, "SHORT-NAME")
            if "/" in name:
                raise CatalogError("SHORT-NAME cannot contain '/'")
            if local != "AR-PACKAGE":
                if path in objects:
                    raise CatalogError(f"duplicate AUTOSAR object {path}")
                objects[path] = node
            prefix = path
        stack.extend((child, prefix, depth + 1) for child in reversed(node))
    return objects


def builtin_base(path: str) -> tuple[str, int] | None:
    prefix = "/AUTOSAR_Platform/BaseTypes/"
    if not path.startswith(prefix):
        return None
    name = path.removeprefix(prefix)
    if name == "boolean":
        return "bool", 8
    match = re.fullmatch(r"(uint|sint|float)(8|16|32|64|128)", name)
    if match is None:
        return None
    return {"uint": "unsigned", "sint": "signed", "float": "float"}[match[1]], int(match[2])


def base_type(ref: str, bits: int, objects: dict[str, ET.Element]) -> str:
    base = objects.get(ref)
    if base is None:
        builtin = builtin_base(ref)
        if builtin is None:
            raise CatalogError(f"unresolved SW-BASE-TYPE reference {ref}")
        kind, reference_bits = builtin
    else:
        if base.tag != NS + "SW-BASE-TYPE":
            raise CatalogError(f"{ref} is not a SW-BASE-TYPE")
        size = text(base, "BASE-TYPE-SIZE")
        encoding = text(base, "BASE-TYPE-ENCODING")
        assert size is not None and encoding is not None
        reference_bits = uint(size, "BASE-TYPE-SIZE", 65531 * 8)
        kind = ENCODING_KIND.get(encoding.upper(), "")
        if not kind:
            raise CatalogError(f"unsupported BASE-TYPE-ENCODING {encoding} at {ref}")
    widths = {"bool": {8}, "signed": {8, 16, 32, 64, 128},
              "unsigned": {8, 16, 32, 64, 128}, "float": {16, 32, 64, 128}}
    if kind in widths and (bits != reference_bits or bits not in widths[kind]):
        raise CatalogError(f"DLT-ARGUMENT LENGTH {bits} conflicts with base type {ref}")
    if kind in ("ascii", "utf8", "raw") and reference_bits != 8:
        raise CatalogError(f"byte-based field requires an eight-bit base type at {ref}")
    return kind


def description(argument: ET.Element) -> str:
    desc = argument.find(NS + "DESC")
    if desc is None:
        raise CatalogError("zero-length DLT-ARGUMENT requires DESC")
    translations = desc.findall(NS + "L-2")
    chosen = next((item for item in translations if item.get("L", "").upper() == "EN"),
                  translations[0] if translations else desc)
    return "".join(chosen.itertext()).strip()


def parse_argument(argument: ET.Element, objects: dict[str, ET.Element]) -> dict:
    name = text(argument, "SHORT-NAME")
    length = text(argument, "LENGTH")
    assert name is not None and length is not None
    bits = uint(length, "LENGTH", 65531 * 8)
    if bits == 0:
        if argument.find(NS + "NETWORK-REPRESENTATION") is not None:
            raise CatalogError(f"static argument {name} also specifies a network representation")
        return {"name": name, "unit_ref": None, "kind": "static", "text": description(argument)}
    if bits % 8 != 0:
        raise CatalogError(f"DLT-ARGUMENT {name} is not byte aligned")
    representation = argument.find(NS + "NETWORK-REPRESENTATION")
    if representation is None:
        raise CatalogError(f"missing NETWORK-REPRESENTATION for {name}")
    alternatives = representation.findall(".//" + NS + "SW-DATA-DEF-PROPS-CONDITIONAL")
    if len(alternatives) > 1:
        raise CatalogError(f"multiple network representations for {name}")
    info = alternatives[0] if alternatives else representation
    for feature in ("COMPU-METHOD-REF", "DATA-CONSTR-REF", "SW-RECORD-LAYOUT-REF",
                    "BYTE-ORDER", "SW-BIT-REPRESENTATION"):
        if info.find(".//" + NS + feature) is not None:
            raise CatalogError(f"unsupported {feature} in {name}")
    ref = text(info, "BASE-TYPE-REF")
    assert ref is not None
    kind = base_type(path_ref(ref, "BASE-TYPE-REF"), bits, objects)
    unit = text(info, "UNIT-REF", required=False)
    return {"name": name, "unit_ref": path_ref(unit, "UNIT-REF") if unit else None,
            "kind": kind, "bits": bits}


def parse_message(node: ET.Element, objects: dict[str, ET.Element]) -> dict:
    message_id = text(node, "MESSAGE-ID")
    message_type = text(node, "MESSAGE-TYPE-INFO")
    assert message_id is not None and message_type is not None
    if message_type not in MESSAGE_TYPES:
        raise CatalogError(f"unsupported MESSAGE-TYPE-INFO {message_type}")
    mstp, mtin = MESSAGE_TYPES[message_type]
    line = text(node, "MESSAGE-LINE-NUMBER", required=False)
    field_elements = node.findall(f"{NS}DLT-ARGUMENTS/{NS}DLT-ARGUMENT")
    if len(field_elements) > 255:
        raise CatalogError("DLT argument list exceeds 255 fields")
    fields = [parse_argument(a, objects) for a in field_elements]
    if sum(f.get("bits", 0) // 8 for f in fields) > 65531:
        raise CatalogError("DLT argument list cannot fit a single DLT message")
    return {
        "message_id": str(uint(message_id, "MESSAGE-ID", 0xFFFFFFFF)),
        "message_type": mstp, "subtype": mtin,
        "source_file": text(node, "MESSAGE-SOURCE-FILE", required=False),
        "source_line": str(uint(line, "MESSAGE-LINE-NUMBER", 0xFFFFFFFF)) if line else None,
        "fields": fields,
    }


def load_catalog(sources: list[Path]) -> dict:
    indexed = index_objects(read_documents(sources))
    resolved: dict[str, dict] = {}
    entries = []
    seen = set()
    field_count = 0
    for ecu_node in indexed.values():
        if ecu_node.tag != NS + "ECU-INSTANCE":
            continue
        config = ecu_node.find(NS + "DLT-CONFIG")
        if config is None:
            continue
        ecu = text(config, "DLT-ECU-ID", required=False)
        if ecu is not None:
            validate_id(ecu, "DLT-ECU-ID")
        for channel in config.findall(f"{NS}DLT-LOG-CHANNELS/{NS}DLT-LOG-CHANNEL"):
            apid, ctid = text(channel, "APPLICATION-ID"), text(channel, "CONTEXT-ID")
            assert apid is not None and ctid is not None
            validate_id(apid, "APPLICATION-ID")
            validate_id(ctid, "CONTEXT-ID")
            for ref in channel.findall(f"{NS}DLT-MESSAGE-REFS/{NS}DLT-MESSAGE-REF"):
                path = path_ref((ref.text or "").strip(), "DLT-MESSAGE-REF")
                if ref.get("DEST", "DLT-MESSAGE") != "DLT-MESSAGE":
                    raise CatalogError(f"invalid destination for DLT message reference {path}")
                if path not in resolved:
                    node = indexed.get(path)
                    if node is None or node.tag != NS + "DLT-MESSAGE":
                        raise CatalogError(f"unresolved DLT-MESSAGE reference {path}")
                    resolved[path] = parse_message(node, indexed)
                message = resolved[path]
                key = (ecu, apid, ctid, message["message_id"])
                if key in seen:
                    raise CatalogError(f"duplicate DLT channel and message binding {key}")
                seen.add(key)
                field_count += len(message["fields"])
                if len(entries) >= 4096 or field_count > 65_535:
                    raise CatalogError("resolved catalogue exceeds message or field budget")
                entries.append({"ecu": ecu, "application": apid, "context": ctid, **message})
    if not entries:
        raise CatalogError("no DLT messages are bound to ECU log channels")
    return {"format": "moondlt.arxml.v1", "messages": entries}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="+", type=Path, help="Classic ARXML documents")
    parser.add_argument("-o", "--output", type=Path, help="new JSON file (defaults to stdout)")
    args = parser.parse_args()
    try:
        data = json.dumps(load_catalog(args.input), ensure_ascii=False, indent=2) + "\n"
        if len(data.encode("utf8")) > MAX_XML_BYTES:
            raise CatalogError("resolved JSON exceeds 8 MiB")
        if args.output is None:
            sys.stdout.buffer.write(data.encode("utf8"))
        else:
            with args.output.open("x", encoding="utf8", newline="\n") as stream:
                stream.write(data)
    except (CatalogError, ET.ParseError, OSError) as exc:
        print(f"ARXML import failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
