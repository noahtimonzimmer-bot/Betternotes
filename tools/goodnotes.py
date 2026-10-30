#!/usr/bin/env python3
"""Reference reader for .goodnotes archives (reverse-engineered, see docs/GOODNOTES_FORMAT.md).

usage: goodnotes.py FILE.goodnotes OUTDIR   -> renders every page as PNG (PDF background + ink)
"""
import io
import os
import struct
import subprocess
import sys
import tempfile
import uuid
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bv4  # noqa: E402
import pbdump  # noqa: E402


def fields(msg):
    """Protobuf message -> {field: [values]}"""
    out = {}
    for f, _, v in pbdump.parse(msg) or []:
        out.setdefault(f, []).append(v)
    return out


def one(d, f, default=None):
    return d.get(f, [default])[0]


def f32(b):
    return struct.unpack("<f", b)[0]


def parse_sig(sig, i=0):
    """'vuA(v)A(S(uu))' -> nested list of tokens: 'v','u','f',('A',[..]),('S',[..])"""
    out = []
    while i < len(sig):
        c = sig[i]
        if c in "vuf":
            out.append(c); i += 1
        elif c in "AS":
            inner, i = parse_sig(sig, i + 2)  # skip 'X('
            out.append((c, inner))
        elif c == ")":
            return out, i + 1
        else:
            raise ValueError(f"unknown tpl type {c!r} in {sig}")
    return out, i


def tpl(raw):
    """Decode a 'tpl' blob. v=u16, u=32-bit (float or int), f=f32, A(x)=u32 count + items,
    S(...)=struct. 32-bit values are returned as floats."""
    assert raw[:4] == b"tpl\0", raw[:4]
    end = raw.index(b"\0", 8)
    sig = raw[8:end].decode()
    d, i = raw[end + 1:], 0

    def val(t):
        nonlocal i
        if t == "v":
            v, = struct.unpack_from("<H", d, i); i += 2; return v
        if t in ("u", "f"):
            v, = struct.unpack_from("<f", d, i); i += 4; return v
        kind, inner = t
        if kind == "S":
            return tuple(val(x) for x in inner)
        n, = struct.unpack_from("<I", d, i); i += 4
        one_ = inner[0] if len(inner) == 1 else ("S", inner)
        return [val(one_) for _ in range(n)]

    tree, _ = parse_sig(sig)
    return sig, [val(t) for t in tree], len(d) - i


def decode_path(blob):
    """Stroke geometry from the compressed path blob. Two variants are known:
    vuA(v)A(S(uu))A(S(uuuu))vA(f)  - fixed width: ops, start points, quadratic segments
    vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))A(S(uu))A(v)A(S(uu))A(S(uuuu))A(u) - variable width
    """
    sig, v, trailing = tpl(bv4.decode(blob))
    if sig == "vuA(v)A(S(uu))A(S(uuuu))vA(f)":
        return dict(sig=sig, width=v[1], ops=v[2], starts=v[3], quads=v[4], trailing=trailing)
    if sig.startswith("vuA(v)A(S(uuuuu))"):
        # pressure pen: start = (x, y, w, ?, ?); segment = (?, cx, cy, cw, ?, ?, x, y, w, ?, ?)
        return dict(sig=sig, width=v[1], ops=v[2],
                    starts=[s[:2] for s in v[3]], quads=[(q[1], q[2], q[6], q[7]) for q in v[4]],
                    widths=[q[8] for q in v[4]], trailing=trailing)
    if sig.endswith("A(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)"):
        # v2 flat layout: same data as variant 1 with flattened float arrays
        o = 1 if sig.startswith("vu") else 0
        width = v[1] if o else 0.0
        st, qd = v[2 + o], v[3 + o]
        return dict(sig=sig, width=width, ops=v[1 + o],
                    starts=[tuple(st[k:k + 2]) for k in range(0, len(st), 2)],
                    quads=[tuple(qd[k:k + 4]) for k in range(0, len(qd), 4)], trailing=trailing)
    raise ValueError(f"unknown path signature {sig}")


def polyline(path, steps=6):
    """Flatten start points + quadratic segments into point lists (one per subpath)."""
    lines, si, qi = [], 0, 0
    cur = None
    for op in path["ops"]:
        if op == 0:
            cur = [path["starts"][si]]; si += 1; lines.append(cur)
        else:
            cx, cy, ex, ey = path["quads"][qi]; qi += 1
            x0, y0 = cur[-1]
            for s in range(1, steps + 1):
                t = s / steps
                a, b, c = (1 - t) ** 2, 2 * (1 - t) * t, t * t
                cur.append((a * x0 + b * cx + c * ex, a * y0 + b * cy + c * ey))
    return lines


def read(path):
    z = zipfile.ZipFile(path)
    names = set(z.namelist())

    def index(name):
        if name not in names:
            return {}
        return {one(fields(m), 1).decode(): one(fields(m), 2).decode()
                for m in pbdump.stream(z.read(name))}

    notes_idx, att_idx = index("index.notes.pb"), index("index.attachments.pb")
    doc = {"title": None, "pages": [], "attachments": {}}
    pages, layers, boards = {}, {}, {}
    for m in pbdump.stream(z.read("index.events.pb")) if "index.events.pb" in names else []:
        ev = fields(m)
        if 30 in ev:
            d = fields(ev[30][0])
            doc["title"] = one(fields(one(d, 2, b"")), 1, b"").decode() or None
        elif 2 in ev:
            p = fields(ev[2][0])
            size = fields(one(p, 8, b""))
            pid = one(p, 2).decode()
            pages[pid] = dict(id=pid, attachment=(one(p, 4) or b"").decode() or None,
                              pdf_page=one(p, 5), width=f32(one(size, 1, b"\0" * 4)),
                              height=f32(one(size, 2, b"\0" * 4)), layers=[])
            doc["pages"].append(pid)
        elif 64 in ev:  # whiteboard: unbounded page
            p = fields(ev[64][0])
            boards[one(p, 2).decode()] = one(fields(one(p, 3, b"")), 1, b"Board").decode()
        elif 54 in ev:  # layer: (layer id, page id, sort key)
            p = fields(ev[54][0])
            key = one(fields(one(p, 4, b"")), 1, b"").decode()
            layers[one(p, 2).decode()] = (one(fields(one(p, 3)), 1).decode(), key)
    # A layer's ink lives in notes/<layer uuid + 1> (observed on every file so far).
    for lid, (pid, key) in sorted(layers.items(), key=lambda kv: kv[1][1]):
        nid = str(uuid.UUID(int=(uuid.UUID(lid).int + 1) % (1 << 128))).upper()
        fname = notes_idx.get(nid)
        if fname is None:
            continue
        if pid not in pages and lid in boards:
            pages[pid] = dict(id=pid, attachment=None, pdf_page=None, width=0.0, height=0.0,
                              board=boards[lid], layers=[])
            doc["pages"].append(pid)
        if pid in pages:
            pages[pid]["layers"].append(fname)
    for aid, fname in att_idx.items():
        doc["attachments"][aid] = fname
    doc["pages"] = [pages[p] for p in doc["pages"]]
    return z, doc


def strokes(z, fname):
    msgs = pbdump.stream(z.read(fname))
    for k in range(1, len(msgs), 2):
        head = fields(msgs[k - 1])
        body = fields(msgs[k])
        if 7 not in body:
            continue
        s = fields(body[7][0])
        if one(head, 3) == 1:  # deleted / erased
            continue
        rgba = fields(one(s, 4, b""))
        color = tuple(f32(one(rgba, c, b"\0\0\x80\x3f")) for c in (1, 2, 3, 4))
        path = decode_path(one(s, 2))
        off = fields(one(s, 6, b""))  # translation from lasso moves
        if off:
            dx, dy = f32(one(off, 1, b"\0" * 4)), f32(one(off, 2, b"\0" * 4))
            path["starts"] = [(x + dx, y + dy) for x, y in path["starts"]]
            path["quads"] = [(a + dx, b + dy, c + dx, d + dy) for a, b, c, d in path["quads"]]
        yield dict(id=one(s, 1).decode(), color=color, path=path)


def render(path, outdir, limit=None):
    from PIL import Image, ImageDraw
    z, doc = read(path)
    os.makedirs(outdir, exist_ok=True)
    for n, pg in enumerate(doc["pages"][:limit]):
        ink = [s for layer in pg["layers"] for s in strokes(z, layer)]
        ox = oy = 0.0
        if pg["width"]:
            W, H, scale = int(pg["width"]), int(pg["height"]), 1.0
        else:  # whiteboard: fit the ink bounding box into 2000 px
            # boards are centred around ~(250000, 250000); ignore stray points via percentiles
            xs = sorted(p[0] for s in ink for line in polyline(s["path"]) for p in line)
            ys = sorted(p[1] for s in ink for line in polyline(s["path"]) for p in line)
            q = lambda a, f: a[int(f * (len(a) - 1))]  # noqa: E731
            x0, x1, y0, y1 = q(xs, .005) - 40, q(xs, .995) + 40, q(ys, .005) - 40, q(ys, .995) + 40
            scale = min(1.0, 2000 / max(x1 - x0, y1 - y0))
            ox, oy = x0, y0
            W, H = int((x1 - x0) * scale), int((y1 - y0) * scale)
        img = Image.new("RGB", (W, H), "white")
        if pg["attachment"] and pg["attachment"] in doc["attachments"]:
            with tempfile.TemporaryDirectory() as t:
                pdf = os.path.join(t, "a.pdf")
                open(pdf, "wb").write(z.read(doc["attachments"][pg["attachment"]]))
                idx = pg["pdf_page"] or 1  # 1-based
                subprocess.run(["pdftoppm", "-png", "-f", str(idx), "-l", str(idx),
                                "-scale-to-x", str(W), "-scale-to-y", str(H), pdf,
                                os.path.join(t, "p")], check=False)
                pngs = [f for f in os.listdir(t) if f.endswith(".png")]
                if pngs:
                    img = Image.open(os.path.join(t, pngs[0])).convert("RGB")
        draw = ImageDraw.Draw(img, "RGBA")
        for s in ink:
            rgba = tuple(int(c * 255) for c in s["color"])
            w = max(1, round(s["path"]["width"] * 2 * scale))
            for line in polyline(s["path"]):
                if len(line) > 1:
                    line = [((x - ox) * scale, (y - oy) * scale) for x, y in line]
                    draw.line(line, fill=rgba, width=w, joint="curve")
        out = os.path.join(outdir, f"page{n + 1:03d}.png")
        img.save(out)
        print(out, f"{len(ink)} strokes", pg.get("board") or pg["pdf_page"])


if __name__ == "__main__":
    render(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else None)
