#!/usr/bin/env python3
"""Schema-less protobuf dumper for reverse engineering .goodnotes files.

usage: pbdump.py FILE [max_depth] [offset]
Recursively tries to interpret length-delimited fields as nested messages.
"""
import struct
import sys


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        if not c & 0x80:
            return r, i
        s += 7


def parse(b):
    """Return list of (field, wiretype, value) or None if not valid protobuf."""
    i, out = 0, []
    try:
        while i < len(b):
            k, i = varint(b, i)
            f, w = k >> 3, k & 7
            if f == 0:
                return None
            if w == 0:
                v, i = varint(b, i)
            elif w == 1:
                v = b[i:i + 8]; i += 8
            elif w == 2:
                n, i = varint(b, i)
                if i + n > len(b):
                    return None
                v = b[i:i + n]; i += n
            elif w == 5:
                v = b[i:i + 4]; i += 4
            else:
                return None
            if w in (1, 5) and len(v) != (8 if w == 1 else 4):
                return None
            out.append((f, w, v))
    except IndexError:
        return None
    return out


def printable(v):
    try:
        s = v.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return s if s and all(c.isprintable() or c in "\n\t" for c in s) else None


def dump(b, depth, maxd, ind=0):
    msg = parse(b)
    if msg is None:
        return False
    p = "  " * ind
    for f, w, v in msg:
        if w == 0:
            print(f"{p}{f}: {v}")
        elif w == 1:
            print(f"{p}{f}: f64 {struct.unpack('<d', v)[0]!r} / u64 {int.from_bytes(v, 'little')}")
        elif w == 5:
            print(f"{p}{f}: f32 {struct.unpack('<f', v)[0]!r} / u32 {int.from_bytes(v, 'little')}")
        else:
            s = printable(v)
            if s is not None and len(s) >= 1 and (parse(v) is None or len(v) < 4):
                print(f"{p}{f}: str {s[:120]!r}")
            elif depth < maxd and v and parse(v) is not None:
                print(f"{p}{f}: {{ ({len(v)} bytes)")
                dump(v, depth + 1, maxd, ind + 1)
                print(f"{p}}}")
            else:
                print(f"{p}{f}: bytes[{len(v)}] {v[:24].hex()}{'…' if len(v) > 24 else ''}")
    return True


def stream(data):
    """GoodNotes files: sequence of varint-length-prefixed messages."""
    i, msgs = 0, []
    while i < len(data):
        n, i = varint(data, i)
        msgs.append(data[i:i + n])
        i += n
    return msgs


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    maxd = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9
    if not data:
        sys.exit("empty file")
    try:
        msgs = stream(data)
    except IndexError:
        msgs = [data]
    print(f"# {len(msgs)} length-prefixed message(s)")
    for k, m in enumerate(msgs[:limit]):
        print(f"--- message {k} ({len(m)} bytes)")
        if not dump(m, 0, maxd):
            print("not valid protobuf:", m[:48].hex())
