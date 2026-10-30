"""Apple 'bv4' framed LZ4 decoder (the compression GoodNotes uses for stroke blobs).

Frame: [bv41][u32 raw_size][u32 comp_size][LZ4 block] ... [bv4$]
       [bv4-][u32 size][raw bytes]   (stored block)
"""
import struct


def lz4_block(src: bytes, raw_size: int, prefix: bytes = b"") -> bytes:
    out = bytearray(prefix)
    i = 0
    while i < len(src):
        t = src[i]; i += 1
        lit = t >> 4
        if lit == 15:
            while True:
                c = src[i]; i += 1; lit += c
                if c != 255:
                    break
        out += src[i:i + lit]; i += lit
        if i >= len(src):
            break
        off = src[i] | (src[i + 1] << 8); i += 2
        ml = t & 15
        if ml == 15:
            while True:
                c = src[i]; i += 1; ml += c
                if c != 255:
                    break
        ml += 4
        for _ in range(ml):
            out.append(out[-off])
    return bytes(out[len(prefix):])


def decode(buf: bytes) -> bytes:
    i, out = 0, bytearray()
    while i + 4 <= len(buf):
        magic = buf[i:i + 4]
        if magic == b"bv4$":
            break
        raw, = struct.unpack_from("<I", buf, i + 4)
        if magic == b"bv41":
            comp, = struct.unpack_from("<I", buf, i + 8)
            out += lz4_block(buf[i + 12:i + 12 + comp], raw, bytes(out[-65536:]))
            i += 12 + comp
        elif magic == b"bv4-":
            out += buf[i + 8:i + 8 + raw]
            i += 8 + raw
        else:
            raise ValueError(f"bad magic {magic!r} at {i}")
    return bytes(out)
