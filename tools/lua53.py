"""Independent reader for EdgeTX Lua 5.3 int32/float32/size32 binary chunks."""
import struct

HEADER = bytes.fromhex("1b4c7561530019930d0a1a0a0404040404") + struct.pack("<if", 0x5678, 370.5)


def validate(data):
    position = 0
    stats = {"functions": 0, "numbers": 0, "strings": 0, "max_code_bytes": 0}

    def take(size):
        nonlocal position
        if size < 0 or size > len(data) - position:
            raise ValueError("Truncated/oversized Lua 5.3 field")
        result = data[position:position + size]
        position += size
        return result

    def count(unit=1):
        value = struct.unpack("<i", take(4))[0]
        if value < 0 or value > (len(data) - position) // unit:
            raise ValueError("Invalid Lua 5.3 vector length")
        return value

    def string():
        size = take(1)[0]
        if size == 255:
            size = struct.unpack("<I", take(4))[0]
        return take(size - 1) if size else b""

    def function(depth=0):
        if depth > 100:
            raise ValueError("Excessive nesting")
        stats["functions"] += 1
        if string():
            raise ValueError("Expected stripped source name")
        take(8)
        params, vararg, stack = take(3)
        if not 1 <= stack <= 250 or params > stack or vararg > 1:
            raise ValueError("Invalid function header")
        code_bytes = count(4) * 4
        take(code_bytes)
        stats["max_code_bytes"] = max(code_bytes, stats["max_code_bytes"])
        for _ in range(count()):
            tag = take(1)[0]
            if tag == 0:
                pass
            elif tag == 1:
                if take(1)[0] > 1:
                    raise ValueError("Invalid boolean")
            elif tag in (3, 19):  # float / integer
                take(4)
                stats["numbers"] += 1
            elif tag in (4, 20):  # short / long string
                string()
                stats["strings"] += 1
            else:
                raise ValueError(f"Invalid Lua 5.3 constant tag {tag}")
        for _ in range(count(2)):
            if take(2)[0] > 1:
                raise ValueError("Invalid upvalue")
        for _ in range(count()):
            function(depth + 1)
        if count(4) or count() or count():
            raise ValueError("Expected stripped debug vectors")

    if take(len(HEADER)) != HEADER:
        raise ValueError("Need EdgeTX Lua 5.3 int32/float32/size32 header")
    take(1)  # main closure upvalue count
    function()
    if position != len(data):
        raise ValueError("Trailing data")
    return stats
