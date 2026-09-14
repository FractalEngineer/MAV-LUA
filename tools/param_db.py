"""Generate small, lazily loaded Lua parameter-name databases."""
import argparse
import json
import re
import struct
from collections import defaultdict
from pathlib import Path


NAME = re.compile(r"[A-Z0-9_]{1,16}")
NUMBERED = re.compile(r"(.+?)(\d+)$")
FOLDER = 0x8000
RECORD_SIZE = 22
def natural(value):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", value)]


def lua_string(value):
    return json.dumps(value, ensure_ascii=True)


def category(name):
    return name.split("_", 1)[0] if "_" in name else "GENERAL"


def record(label, offset, count, folder=False):
    encoded = label.encode("ascii")
    if len(encoded) > 16 or count < 1 or count >= FOLDER:
        raise ValueError(f"invalid database record: {label} ({count})")
    return encoded + b"\0" * (16 - len(encoded)) + struct.pack(
        "<IH", offset, count | (FOLDER if folder else 0))


def generate(source, output, version, vehicle, code):
    document = json.loads(source.read_text(encoding="utf-8"))
    names = sorted({
        name
        for section in document.values() if isinstance(section, dict)
        for name in section if NAME.fullmatch(name) and not name.startswith(("SIM_", "SITL_"))
    }, key=natural)
    if not names:
        raise SystemExit(f"{source}: expected generated ArduPilot parameter maps")
    provisional = defaultdict(list)
    for name in names:
        provisional[category(name)].append(name)
    groups = defaultdict(list)
    for label, members in provisional.items():
        if label != "GENERAL" and len(members) < 2:
            groups["GENERAL"].extend(members)
        else:
            groups[label].extend(members)
    numbered = defaultdict(list)
    for label in groups:
        match = NUMBERED.fullmatch(label)
        if match:
            numbered[match.group(1)].append(label)
    families = {
        base: sorted(([base] if base in groups else []) + labels, key=natural)
        for base, labels in numbered.items() if len(labels) >= 2
    }
    nested = {label for labels in families.values() for label in labels}
    top = sorted((set(groups) - nested) | set(families),
                 key=lambda value: (value != "GENERAL", natural(value)))
    children = [label for family in top for label in families.get(family, ())]
    prefix = f"a{version.replace('.', '')}{code}"
    output.mkdir(parents=True, exist_ok=True)
    top_index = bytearray()
    child_index = bytearray()
    database = bytearray()
    data_offset = (len(top) + len(children)) * RECORD_SIZE
    locations = {}
    for label in sorted(groups, key=natural):
        members = sorted(groups[label], key=natural)
        offset = data_offset + len(database)
        locations[label] = (offset, len(members))
        for name in members:
            encoded = name.encode("ascii")
            database.extend(encoded)
            database.extend(b"\0" * (16 - len(encoded)))
    child_offset = len(top) * RECORD_SIZE
    for label in top:
        if label in families:
            top_index.extend(record(label, child_offset, len(families[label]), True))
            child_offset += len(families[label]) * RECORD_SIZE
        else:
            top_index.extend(record(label, *locations[label]))
    for label in children:
        child_index.extend(record(label, *locations[label]))
    (output / f"{prefix}.pdb").write_bytes(top_index + child_index + database)
    (output / f"{prefix}.lua").write_text(
        "-- SPDX-License-Identifier: GPL-3.0-or-later\n"
        f"-- Generated from ArduPilot {version} {vehicle} parameter metadata.\n"
        f"return {{{lua_string(version)},{lua_string(vehicle)},"
        f"{lua_string('/SCRIPTS/MAV/DB/' + prefix + '.pdb')},{len(top)}}}\n",
        encoding="ascii", newline="\n")
    return len(names), len(top)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, default=Path("src/SCRIPTS/MAV/DB"))
    parser.add_argument("vehicle", help="Vehicle name used in the manifest")
    parser.add_argument("code", help="One-character database key")
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    count, groups = generate(args.source, args.output, args.version, args.vehicle, args.code)
    print(f"{args.version} {args.vehicle}: {count} names in {groups} top-level categories")


if __name__ == "__main__":
    main()
