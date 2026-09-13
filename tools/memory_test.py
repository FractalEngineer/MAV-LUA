"""Build a Lua 5.3 host runner that records and optionally limits Lua allocations.

Uses the bootstrapped toolchain sources. Host pointers are wider than radio
pointers: this measures relative regressions, not a radio's available heap.
"""
from pathlib import Path
import shutil
import subprocess
import os

root = Path(__file__).resolve().parents[1]
src = root / '.build/lua-5.3.6/src'
main = (src / 'lua.c').read_text()
allocator = r'''
static size_t mem_used, mem_peak, mem_limit;
static void *memory_alloc(void *ud, void *ptr, size_t old, size_t size) {
  (void)ud;
  if (!ptr) old = 0;
  if (!size) { free(ptr); mem_used -= old; return NULL; }
  if (mem_limit && mem_used - old + size > mem_limit) return NULL;
  void *next = realloc(ptr, size);
  if (next) {
    mem_used = mem_used - old + size;
    if (mem_used > mem_peak) mem_peak = mem_used;
  }
  return next;
}
static int memory_stats(lua_State *L) {
  lua_pushinteger(L, mem_used);
  lua_pushinteger(L, mem_peak);
  if (lua_toboolean(L, 1)) mem_peak = mem_used;
  return 2;
}
'''
main = main.replace('static int pmain (lua_State *L)', allocator + '\nstatic int pmain (lua_State *L)')
main = main.replace('  luaL_openlibs(L);', '''  luaL_openlibs(L);
  lua_pushcfunction(L, memory_stats);
  lua_setglobal(L, "memoryStats");''')
main = main.replace('lua_State *L = luaL_newstate();', '''lua_State *L;
  const char *limit = getenv("MAV_TEST_HEAP_LIMIT");
  mem_limit = limit ? strtoul(limit, NULL, 10) : 0;
  L = lua_newstate(memory_alloc, NULL);''')
assert 'lua_newstate(memory_alloc' in main
build = root / '.build'
(build / 'lua-memory.c').write_text(main)
common = sorted(str(p) for p in src.glob('*.c') if p.name not in {'lua.c', 'luac.c'})
output = build / ('lua-memory.exe' if os.name == 'nt' else 'lua-memory')
subprocess.run([shutil.which('gcc') or 'gcc', '-O2', '-DLUA_32BITS', '-DLUA_COMPAT_5_2',
                '-I', str(src), *common, str(build / 'lua-memory.c'), '-o', str(output), '-lm'], check=True)
print(output)
