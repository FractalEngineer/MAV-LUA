"""Independent reader for FreedomTX/OpenTX Lua 5.2 compiled chunks.

The ordinary Lua header does NOT identify the firmware's patched constant tags.
Walk every function/constant instead of trusting a compiler's header alone.
"""
import struct

HEADER = bytes.fromhex("1b4c7561520001040404080019930d0a1a0a")


def validate(data, stripped=True):
    position = 0
    stats = {"functions": 0, "numbers": 0, "strings": 0, "max_code_bytes": 0}

    def take(size):
        nonlocal position
        if size < 0 or size > len(data) - position:
            raise ValueError(f"Truncated/oversized chunk field at byte {position}")
        result = data[position:position + size]
        position += size
        return result

    def integer():
        return struct.unpack("<i", take(4))[0]

    def count(min_bytes=1):
        value = integer()
        if value < 0 or value > (len(data) - position) // min_bytes:
            raise ValueError(f"Invalid vector length {value} at byte {position - 4}")
        return value

    def string():
        size = struct.unpack("<I", take(4))[0]
        value = take(size)
        if value and value[-1] != 0:
            raise ValueError("Missing string terminator")
        return value

    def function(depth=0):
        if depth > 100:
            raise ValueError("Excessive function nesting")
        stats["functions"] += 1
        take(8)  # line defined / last line defined
        params, vararg, stack = take(3)
        if not 1 <= stack <= 250 or params > stack or vararg > 1:
            raise ValueError("Invalid function header")
        code_bytes = count(4) * 4
        stats["max_code_bytes"] = max(stats["max_code_bytes"], code_bytes)
        for (instruction,) in struct.iter_unpack("<I", take(code_bytes)):
            opcode, arguments = instruction & 63, (instruction >> 23) & 511
            if opcode == 30 and arguments == 1:  # OP_TAILCALL, zero arguments
                raise ValueError("Zero-argument tail call is unsafe on FreedomTX 1.40; assign the result before returning")
        for _ in range(count()):
            tag = take(1)[0]
            if tag == 0:  # nil
                pass
            elif tag == 1:  # boolean
                if take(1)[0] > 1:
                    raise ValueError("Invalid boolean")
            elif tag == 5:  # firmware number; stock Lua uses 3
                take(8)
                stats["numbers"] += 1
            elif tag == 6:  # firmware string; stock Lua uses 4
                string()
                stats["strings"] += 1
            else:
                raise ValueError(f"Invalid FreedomTX constant tag {tag} at byte {position - 1}; rebuild the compiler")
        for _ in range(count()):
            function(depth + 1)
        upvalues = count(2)
        for _ in range(upvalues):
            if take(2)[0] > 1:
                raise ValueError("Invalid upvalue descriptor")
        debug_source = string()
        lines = count(4)
        take(lines * 4)
        locals_count = count()
        for _ in range(locals_count):
            string()
            take(8)
        names = count()
        if names > upvalues:
            raise ValueError("Too many upvalue names")
        for _ in range(names):
            string()
        if stripped and (debug_source or lines or locals_count or names):
            raise ValueError("Radio package must use stripped bytecode")

    if take(len(HEADER)) != HEADER:
        raise ValueError("Need Lua 5.2 / little endian / string-size32 / double64 firmware header")
    function()
    if position != len(data):
        raise ValueError("Trailing data after compiled chunk")
    return stats
