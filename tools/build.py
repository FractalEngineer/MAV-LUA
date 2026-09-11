"""Build a source package and optional stripped Lua 5.2 Tango candidate."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

from lua52 import validate

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
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


def package(compiler=None):
    BUILD.mkdir(exist_ok=True)
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    files = sorted((ROOT / "src").rglob("*.lua"))
    outputs = []
    for binary in ([False, True] if compiler else [False]):
        name = "MAV-LUA-tango2-freedomtx-r2.zip" if binary else "MAV-LUA-source.zip"
        output = dist / name
        staging = output.with_suffix(".zip.tmp")
        with zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                rel = path.relative_to(ROOT / "src").as_posix()
                if binary:
                    # Tango only needs the one permanent telemetry script.
                    if rel.startswith("WIDGETS/"):
                        continue
                    compiled = BUILD / "MAV.lua"
                    subprocess.run([str(compiler), "-s", "-o", str(compiled), str(path)], check=True)
                    data = compiled.read_bytes()
                    try:
                        stats = validate(data)
                    except ValueError as error:
                        raise SystemExit(f"Compiler produced incompatible bytecode: {error}") from error
                    print(f"{rel}: {len(data)} stripped bytes; {stats['functions']} functions; firmware tags verified")
                else:
                    data = path.read_bytes()
                info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
                if binary:
                    # FreedomTX prefers a same-name .luac cache when present.
                    # Replace both names so an older cache cannot shadow a fix.
                    info = zipfile.ZipInfo(str(Path(rel).with_suffix(".luac")).replace("\\", "/"),
                                           date_time=(2026, 1, 1, 0, 0, 0))
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, data)
            for doc in ("README.md", "docs/HARDWARE-TEST.md", "docs/PROTOCOL.md", "LICENSE"):
                info = zipfile.ZipInfo(doc, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, (ROOT / doc).read_bytes())
            if binary:
                # Ship corresponding readable source with binary distributions.
                info = zipfile.ZipInfo("SOURCE/MAV.lua", date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, (ROOT / "src/SCRIPTS/TELEMETRY/MAV.lua").read_bytes())
        staging.replace(output)
        outputs.append(output)
    (dist / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in outputs))
    print((dist / "SHA256SUMS.txt").read_text(), end="")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", action="store_true", help="Download/check Lua sources and build with gcc")
    parser.add_argument("--archive", type=Path, help="Use an already downloaded Lua 5.2.4 tarball")
    parser.add_argument("--luac", type=Path, help="Compile Tango candidate using a firmware-compatible Lua 5.2 compiler")
    parser.add_argument("--toolchain-only", action="store_true")
    args = parser.parse_args()
    if args.bootstrap:
        bootstrap(args.archive)
    if not args.toolchain_only:
        package(args.luac)
