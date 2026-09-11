"""Build Lua 5.3.6 tools for EdgeTX 2.11 RC1+: int32, float32, size32 chunks."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
SHA256 = "fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60"


def bootstrap(archive=None):
    BUILD.mkdir(exist_ok=True)
    archive = Path(archive) if archive else BUILD / "lua-5.3.6.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve("https://www.lua.org/ftp/lua-5.3.6.tar.gz", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("Lua 5.3.6 source checksum mismatch")
    with tarfile.open(archive) as source:
        source.extractall(BUILD, filter="data")
    src = BUILD / "lua-5.3.6/src"
    # Match EdgeTX's numeric types and serialize long-string lengths as uint32
    # on a 64-bit build host too, rather than only changing the header size byte.
    patches = {
        "ldump.c": [("size_t size = tsslen(s) + 1;", "unsigned int size = (unsigned int)tsslen(s) + 1;"),
                    ("DumpByte(sizeof(size_t), D);", "DumpByte(sizeof(unsigned int), D);")],
        "lundump.c": [("size_t size = LoadByte(S);", "unsigned int size = LoadByte(S);"),
                      ("checksize(S, size_t);", "checksize(S, unsigned int);")],
    }
    for name, replacements in patches.items():
        path = src / name
        content = path.read_text()
        for old, new in replacements:
            if content.count(old) != 1:
                raise SystemExit(f"Unexpected Lua source: {name}: {old}")
            content = content.replace(old, new)
        path.write_text(content)
    compiler = shutil.which("gcc")
    if not compiler:
        raise SystemExit("gcc is required")
    common = sorted(str(p) for p in src.glob("*.c") if p.name not in {"lua.c", "luac.c"})
    for target in ("lua", "luac"):
        output = BUILD / (target + "53" + (".exe" if __import__("os").name == "nt" else ""))
        subprocess.run([compiler, "-O2", "-DLUA_32BITS", "-DLUA_COMPAT_5_2", *common,
                        str(src / f"{target}.c"), "-o", str(output), "-lm"], check=True)
    print("Built EdgeTX 2.11 RC1+ Lua 5.3 tools (int32/float32/size32).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    bootstrap(parser.parse_args().archive)
