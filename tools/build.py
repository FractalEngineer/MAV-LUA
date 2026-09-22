"""Build modern source and legacy precompiled radio packages."""
import argparse
import hashlib
import os
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import time
import urllib.request
import zipfile

from lua52 import validate
from lua53 import validate as validate53

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"


def portable_bytes(path):
    """Keep packaged source/docs identical across Windows and Linux checkouts."""
    data = path.read_bytes()
    if path.suffix.lower() in {".lua", ".pdb", ".md", ".txt"} or path.name == "LICENSE":
        return data.replace(b"\r\n", b"\n")
    return data


LUA_SHA256 = "b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b"
LUA_URL = "https://www.lua.org/ftp/lua-5.2.4.tar.gz"


def bootstrap(archive=None):
    BUILD.mkdir(exist_ok=True)
    archive = Path(archive) if archive else BUILD / "lua-5.2.4.tar.gz"
    if not archive.exists():
        print(f"Downloading {LUA_URL}", flush=True)
        urllib.request.urlretrieve(LUA_URL, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != LUA_SHA256:
        raise SystemExit("Lua source checksum mismatch")
    with tarfile.open(archive) as source:
        source.extractall(BUILD, filter="data")
    src = BUILD / "lua-5.2.4" / "src"
    # Firmware chunks have 32-bit serialized string sizes, even on a 64-bit host.
    # Keep host allocations native. This is the upstream reference's chunk ABI:
    # Lua 5.2, little endian, int=4, string size=4, instruction=4, double=8.
    # Firmware reserves value tags 2/3 for read-only tables/light functions.
    # Serialize number/string as 5/6; leave the host VM's internal tags native.
    patches = {
        "ldump.c": [("size_t size=0;", "unsigned int size=0;"),
                    ("size_t size=s->tsv.len+1;", "unsigned int size=s->tsv.len+1;"),
                    ("DumpChar(ttypenv(o),D);",
                     "DumpChar(ttypenv(o)==LUA_TNUMBER ? 5 : ttypenv(o)==LUA_TSTRING ? 6 : ttypenv(o),D);")],
        "lundump.c": [(" size_t size;", " unsigned int size;"),
                      ("sizeof(size_t)", "sizeof(unsigned int)"),
                      ("int t=LoadChar(S);", "int t=LoadChar(S);\n"
                       "  if (t==5) t=LUA_TNUMBER;\n"
                       "  else if (t==6) t=LUA_TSTRING;\n"
                       "  else if (t!=LUA_TNIL && t!=LUA_TBOOLEAN) error(S,\"invalid firmware constant tag in\");")],
    }
    for name, replacements in patches.items():
        path = src / name
        text = path.read_text()
        for old, new in replacements:
            if text.count(old) != 1:
                raise SystemExit(f"Unexpected Lua source: {name}: {old}")
            text = text.replace(old, new)
        path.write_text(text)
    compiler = shutil.which("gcc")
    if not compiler:
        raise SystemExit("gcc is required for --bootstrap")
    common = sorted(str(p) for p in src.glob("*.c") if p.name not in {"lua.c", "luac.c"})
    for target in ("lua", "luac"):
        output = BUILD / (target + (".exe" if __import__("os").name == "nt" else ""))
        subprocess.run([compiler, "-O2", "-DLUA_ANSI", *common, str(src / f"{target}.c"),
                        "-o", str(output), "-lm"], check=True)
    print("Built Lua 5.2.4 host test runner and firmware-format compiler.")


def package(compiler=None, compiler53=None, version="dev"):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
        raise SystemExit("Invalid package version")
    BUILD.mkdir(exist_ok=True)
    compiler = compiler or BUILD / ("luac.exe" if os.name == "nt" else "luac")
    if not Path(compiler).is_file():
        raise SystemExit("A legacy compiler is required: use --bootstrap or --luac PATH")
    dist = ROOT / "dist" / version
    dist.mkdir(parents=True, exist_ok=True)
    # Firmware compares source/cache modification times. Never stamp new source
    # with a fixed old date. Release CI can use the tag's SOURCE_DATE_EPOCH.
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", time.time()))
    timestamp = time.gmtime(epoch)[:6] if "SOURCE_DATE_EPOCH" in os.environ else time.localtime(epoch)[:6]
    files = sorted((ROOT / "src").rglob("*.lua"))
    assets = sorted((ROOT / "src").rglob("*.pdb"))
    outputs = []
    # Modern bytecode is a host validation artifact, never a third deliverable.
    if compiler53:
        for path in files:
            rel = path.relative_to(ROOT / "src")
            compiled = BUILD / "post" / rel
            compiled.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(compiler53), "-s", "-o", str(compiled), str(path)], check=True)
            validate53(compiled.read_bytes())
            if rel.as_posix() == "SCRIPTS/TELEMETRY/MAV.lua":
                (BUILD / "MAV-post.lua").write_bytes(compiled.read_bytes())
        for path in assets:
            rel = path.relative_to(ROOT / "src")
            staged = BUILD / "post" / rel
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_bytes(path.read_bytes())
    for kind, target_compiler in (("source", None), ("precompiled", compiler)):
        binary = target_compiler is not None
        family = "pre" if binary else "post"
        name = f"MAV-LUA-{version}_{kind}.zip"
        output = dist / name
        staging = output.with_suffix(".zip.tmp")
        with zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                rel = path.relative_to(ROOT / "src").as_posix()
                if binary:
                    compiled = BUILD / family / rel
                    compiled.parent.mkdir(parents=True, exist_ok=True)
                    subprocess.run([str(target_compiler), "-s", "-o", str(compiled), str(path)], check=True)
                    data = compiled.read_bytes()
                    try:
                        stats = (validate if family == "pre" else validate53)(data)
                    except ValueError as error:
                        raise SystemExit(f"Compiler produced incompatible bytecode: {error}") from error
                    print(f"{family}/{rel}: {len(data)} stripped bytes; {stats['functions']} functions; ABI verified")
                    if rel == "SCRIPTS/TELEMETRY/MAV.lua":
                        (BUILD / ("MAV.lua" if family == "pre" else "MAV-post.lua")).write_bytes(data)
                else:
                    data = portable_bytes(path)
                info = zipfile.ZipInfo(rel, date_time=timestamp)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
                if binary:
                    # Firmware may prefer a same-name .luac cache when present.
                    # Replace both names so an older cache cannot shadow a fix.
                    info = zipfile.ZipInfo(str(Path(rel).with_suffix(".luac")).replace("\\", "/"),
                                           date_time=timestamp)
                    info.create_system = 3
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, data)
            for path in assets:
                rel = path.relative_to(ROOT / "src").as_posix()
                info = zipfile.ZipInfo(rel, date_time=timestamp)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes())
            docs = ["README.md", "CHANGELOG.md", "LICENSE", "docs/PROTOCOL.md",
                    "docs/PARAMETER-DATABASES.md", "docs/HARDWARE-TEST.md"]
            docs += [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / 'docs/images').glob('*.png'))]
            for doc in docs:
                info = zipfile.ZipInfo(doc, date_time=timestamp)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, portable_bytes(ROOT / doc))
            # Card helper scripts live in src/ so they are copied to the SD card with the rest.
            # They are archived at the package root, because on the card they sit beside SCRIPTS.
            for helper in sorted((ROOT / 'src').glob('*.bat')):
                info = zipfile.ZipInfo(helper.name, date_time=timestamp)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, portable_bytes(helper))
            info = zipfile.ZipInfo("VERSION.txt", date_time=timestamp)
            info.create_system = 3
            compatibility = "Before EdgeTX 2.11 RC1" if binary else "EdgeTX 2.11 RC1 or newer"
            archive.writestr(info, f"{version}\n{kind}\n{compatibility}\nPages: Navigation, Messages, Parameters\nPAGE changes pages; ENTER selects\nParameters require EdgeTX 2.11 and the ELRS TX bridge\n")
            if binary:
                for path in files:
                    rel = path.relative_to(ROOT / "src").as_posix()
                    info = zipfile.ZipInfo("SOURCE/" + rel, date_time=timestamp)
                    info.create_system = 3
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, portable_bytes(path))
        staging.replace(output)
        outputs.append(output)
    (dist / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in outputs), newline="\n")
    print((dist / "SHA256SUMS.txt").read_text(), end="")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", action="store_true", help="Download/check Lua sources and build with gcc")
    parser.add_argument("--archive", type=Path, help="Use an already downloaded Lua 5.2.4 tarball")
    parser.add_argument("--luac", type=Path, help="Legacy firmware-compatible Lua 5.2 compiler")
    parser.add_argument("--luac-post", type=Path, help="Optional Lua 5.3 compiler for host validation only; no additional ZIP")
    parser.add_argument("--version", default="dev", help="Release tag or dev; included in all artifact names")
    parser.add_argument("--toolchain-only", action="store_true")
    args = parser.parse_args()
    if args.bootstrap:
        bootstrap(args.archive)
    if not args.toolchain_only:
        package(args.luac, args.luac_post, args.version)
