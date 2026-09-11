"""Build a host runner reproducing FreedomTX 1.40's C-tail-call fallthrough.

This isolates that VM defect and supplies a real C cursor getter. It is not a
radio emulator. Requires the existing tools/build.py bootstrapped sources.
"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
SRC = BUILD / "lua-5.2.4/src"

vm = (SRC / "lvm.c").read_text()
assert vm.count("vmcase(OP_TAILCALL,") == 1
# Release_V1.40/lvm.c has no break between OP_TAILCALL and OP_RETURN.
(BUILD / "lvm-freedomtx140.c").write_text(vm.replace("vmcase(OP_TAILCALL,", "vmcasenb(OP_TAILCALL,"))
main = (SRC / "lua.c").read_text()
main = main.replace('  luaL_openlibs(L);', '''  luaL_openlibs(L);
  lua_pushcfunction(L, mav_test_cursor);
  lua_setglobal(L, "firmwareCursor");''')
main = main.replace('static int pmain (lua_State *L)', '''static int mav_test_cursor(lua_State *L) {
  lua_getglobal(L, "firmwareCursorValue");
  return 1;
}

static int pmain (lua_State *L)''')
assert "static int mav_test_cursor" in main
(BUILD / "lua-freedomtx140.c").write_text(main)
common = sorted(str(p) for p in SRC.glob("*.c") if p.name not in {"lua.c", "luac.c", "lvm.c"})
output = BUILD / ("lua-freedomtx140.exe" if __import__("os").name == "nt" else "lua-freedomtx140")
subprocess.run([shutil.which("gcc") or "gcc", "-O2", "-DLUA_ANSI", "-I", str(SRC), *common,
                str(BUILD / "lvm-freedomtx140.c"), str(BUILD / "lua-freedomtx140.c"),
                "-o", str(output), "-lm"], check=True)
print(output)
