import Foundation
import CoreGraphics
import ZIPFoundation

// Reader for .goodnotes archives. Format notes: docs/GOODNOTES_FORMAT.md
// Reference implementation (verified against GoodNotes renders): tools/goodnotes.py

// MARK: - Protobuf (schema-less)

struct ProtoFields {
    enum Value { case varint(UInt64), bytes([UInt8]), fixed32(UInt32), fixed64(UInt64) }
    private(set) var values: [Int: [Value]] = [:]

    init(_ b: [UInt8]) throws {
        var i = 0
        while i < b.count {
            let key = try ProtoFields.varint(b, &i)
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: values[field, default: []].append(.varint(try ProtoFields.varint(b, &i)))
            case 1:
                guard i + 8 <= b.count else { throw GoodNotesError.corrupt }
                values[field, default: []].append(.fixed64(b[i..<i + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }))
                i += 8
            case 2:
                let n = Int(try ProtoFields.varint(b, &i))
                guard i + n <= b.count else { throw GoodNotesError.corrupt }
                values[field, default: []].append(.bytes(Array(b[i..<i + n])))
                i += n
            case 5:
                guard i + 4 <= b.count else { throw GoodNotesError.corrupt }
                values[field, default: []].append(.fixed32(b[i..<i + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
                i += 4
            default: throw GoodNotesError.corrupt
            }
        }
    }

    static func varint(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard i < b.count, shift < 64 else { throw GoodNotesError.corrupt }
            let c = b[i]; i += 1
            result |= UInt64(c & 0x7F) << shift
            if c & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// Splits a file of varint-length-prefixed messages.
    static func stream(_ b: [UInt8]) throws -> [[UInt8]] {
        var i = 0, out: [[UInt8]] = []
        while i < b.count {
            let n = Int(try varint(b, &i))
            guard i + n <= b.count else { throw GoodNotesError.corrupt }
            out.append(Array(b[i..<i + n])); i += n
        }
        return out
    }

    func has(_ f: Int) -> Bool { values[f] != nil }
    func int(_ f: Int) -> UInt64? {
        if case .varint(let v)? = values[f]?.first { return v }; return nil
    }
    func bytes(_ f: Int) -> [UInt8]? {
        if case .bytes(let v)? = values[f]?.first { return v }; return nil
    }
    func string(_ f: Int) -> String? { bytes(f).flatMap { String(bytes: $0, encoding: .utf8) } }
    func float(_ f: Int) -> Float? {
        if case .fixed32(let v)? = values[f]?.first { return Float(bitPattern: v) }; return nil
    }
    func message(_ f: Int) -> ProtoFields? { bytes(f).flatMap { try? ProtoFields($0) } }
}

enum GoodNotesError: LocalizedError {
    case notAnArchive, corrupt, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "Die Datei ist kein gültiges .goodnotes-Archiv."
        case .corrupt: return "Die GoodNotes-Datei ist beschädigt."
        case .unsupported(let s): return "Nicht unterstütztes GoodNotes-Format: \(s)"
        }
    }
}

// MARK: - bv4 (Apple LZ4 framing)

enum BV4 {
    static func decode(_ buf: [UInt8]) throws -> [UInt8] {
        var i = 0, out: [UInt8] = []
        func u32(_ at: Int) -> Int { Int(buf[at]) | Int(buf[at + 1]) << 8 | Int(buf[at + 2]) << 16 | Int(buf[at + 3]) << 24 }
        while i + 4 <= buf.count {
            let magic = String(bytes: buf[i..<i + 4], encoding: .ascii)
            if magic == "bv4$" { break }
            guard i + 8 <= buf.count else { throw GoodNotesError.corrupt }
            let raw = u32(i + 4)
            if magic == "bv41" {
                let comp = u32(i + 8)
                guard i + 12 + comp <= buf.count else { throw GoodNotesError.corrupt }
                try lz4Block(buf, from: i + 12, to: i + 12 + comp, into: &out)
                i += 12 + comp
            } else if magic == "bv4-" {
                guard i + 8 + raw <= buf.count else { throw GoodNotesError.corrupt }
                out += buf[i + 8..<i + 8 + raw]; i += 8 + raw
            } else {
                throw GoodNotesError.corrupt
            }
        }
        return out
    }

    /// Raw LZ4 block; matches may reference earlier output (previous blocks act as dictionary).
    private static func lz4Block(_ s: [UInt8], from start: Int, to end: Int, into out: inout [UInt8]) throws {
        var i = start
        func length(_ base: Int) throws -> Int {
            var n = base
            if base == 15 {
                while true {
                    guard i < end else { throw GoodNotesError.corrupt }
                    let c = Int(s[i]); i += 1; n += c
                    if c != 255 { break }
                }
            }
            return n
        }
        while i < end {
            let token = Int(s[i]); i += 1
            let lit = try length(token >> 4)
            guard i + lit <= end else { throw GoodNotesError.corrupt }
            out += s[i..<i + lit]; i += lit
            if i >= end { break }
            guard i + 2 <= end else { throw GoodNotesError.corrupt }
            let offset = Int(s[i]) | Int(s[i + 1]) << 8; i += 2
            let match = try length(token & 15) + 4
            guard offset > 0, offset <= out.count else { throw GoodNotesError.corrupt }
            for _ in 0..<match { out.append(out[out.count - offset]) }
        }
    }
}

// MARK: - tpl container

indirect enum TplValue {
    case int(UInt16), float(Float), list([TplValue]), tuple([TplValue])

    var floatValue: Float { if case .float(let f) = self { return f }; if case .int(let v) = self { return Float(v) }; return 0 }
    var intValue: Int { if case .int(let v) = self { return Int(v) }; return 0 }
    var items: [TplValue] { switch self { case .list(let a), .tuple(let a): return a; default: return [] } }
}

enum Tpl {
    private indirect enum T { case v, u, a(T), s([T]) }

    static func decode(_ raw: [UInt8]) throws -> (signature: String, values: [TplValue]) {
        guard raw.count > 9, raw[0..<4] == [0x74, 0x70, 0x6C, 0x00] else { throw GoodNotesError.corrupt }
        guard let nul = raw[8...].firstIndex(of: 0) else { throw GoodNotesError.corrupt }
        let sig = String(decoding: raw[8..<nul], as: UTF8.self)
        var p = Array(sig.utf8)[...]
        let types = try parse(&p)
        var i = nul + 1
        func value(_ t: T) throws -> TplValue {
            switch t {
            case .v:
                guard i + 2 <= raw.count else { throw GoodNotesError.corrupt }
                defer { i += 2 }
                return .int(UInt16(raw[i]) | UInt16(raw[i + 1]) << 8)
            case .u:
                guard i + 4 <= raw.count else { throw GoodNotesError.corrupt }
                defer { i += 4 }
                let bits = UInt32(raw[i]) | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]) << 16 | UInt32(raw[i + 3]) << 24
                return .float(Float(bitPattern: bits))
            case .s(let ts):
                return .tuple(try ts.map(value))
            case .a(let inner):
                guard i + 4 <= raw.count else { throw GoodNotesError.corrupt }
                let n = Int(raw[i]) | Int(raw[i + 1]) << 8 | Int(raw[i + 2]) << 16 | Int(raw[i + 3]) << 24
                i += 4
                guard n <= raw.count else { throw GoodNotesError.corrupt }
                return .list(try (0..<n).map { _ in try value(inner) })
            }
        }
        return (sig, try types.map(value))
    }

    private static func parse(_ p: inout ArraySlice<UInt8>) throws -> [T] {
        var out: [T] = []
        while let c = p.first {
            p = p.dropFirst()
            switch c {
            case UInt8(ascii: "v"): out.append(.v)
            case UInt8(ascii: "u"), UInt8(ascii: "f"): out.append(.u)
            case UInt8(ascii: "A"), UInt8(ascii: "S"):
                p = p.dropFirst() // "("
                let inner = try parse(&p)
                if c == UInt8(ascii: "S") { out.append(.s(inner)) }
                else { out.append(.a(inner.count == 1 ? inner[0] : .s(inner))) }
            case UInt8(ascii: ")"): return out
            default: throw GoodNotesError.unsupported("tpl type \(Character(Unicode.Scalar(c)))")
            }
        }
        return out
    }
}

// MARK: - Document model

struct GNStroke {
    var color: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    var width: CGFloat
    /// Flattened subpaths in page coordinates.
    var lines: [[CGPoint]]
}

struct GNPage {
    var id: String
    var attachment: String?      // attachment id
    var pdfPage: Int?            // 1-based
    var size: CGSize?            // nil = whiteboard
    var title: String?
    var layerFiles: [String] = []
}

struct GoodNotesFile {
    var title: String?
    var pages: [GNPage]
    var attachmentFiles: [String: String]   // id -> path in archive
    private let archive: Archive

    init(url: URL) throws {
        guard let archive = Archive(url: url, accessMode: .read) else { throw GoodNotesError.notAnArchive }
        self.archive = archive

        func index(_ name: String) throws -> [String: String] {
            guard archive[name] != nil else { return [:] }
            var out: [String: String] = [:]
            for m in try ProtoFields.stream(try GoodNotesFile.read(archive, name)) {
                let f = try ProtoFields(m)
                if let k = f.string(1), let v = f.string(2) { out[k] = v }
            }
            return out
        }
        let notesIndex = try index("index.notes.pb")
        attachmentFiles = try index("index.attachments.pb")

        var title: String?
        var pages: [String: GNPage] = [:], order: [String] = []
        var layers: [(layer: String, page: String, key: String)] = []
        var boards: [String: String] = [:]
        if archive["index.events.pb"] != nil {
            for m in try ProtoFields.stream(try GoodNotesFile.read(archive, "index.events.pb")) {
                let ev = try ProtoFields(m)
                if let d = ev.message(30) {
                    title = d.message(2)?.string(1)
                } else if let p = ev.message(2), let id = p.string(2) {
                    let size = p.message(8)
                    pages[id] = GNPage(id: id, attachment: p.string(4), pdfPage: p.int(5).map { Int($0) },
                                       size: CGSize(width: CGFloat(size?.float(1) ?? 1091.64),
                                                    height: CGFloat(size?.float(2) ?? 1543.74)))
                    order.append(id)
                } else if let b = ev.message(64), let id = b.string(2) {
                    boards[id] = b.message(3)?.string(1) ?? "Board"
                } else if let l = ev.message(54), let id = l.string(2), let page = l.message(3)?.string(1) {
                    layers.append((id, page, l.message(4)?.string(1) ?? ""))
                }
            }
        }
        for l in layers.sorted(by: { $0.key < $1.key }) {
            guard let file = notesIndex[GoodNotesFile.uuidPlusOne(l.layer)] else { continue }
            if pages[l.page] == nil, let name = boards[l.layer] {
                pages[l.page] = GNPage(id: l.page, size: nil, title: name)
                order.append(l.page)
            }
            pages[l.page]?.layerFiles.append(file)
        }
        self.title = title
        self.pages = order.compactMap { pages[$0] }
    }

    func data(_ path: String) throws -> Data { Data(try GoodNotesFile.read(archive, path)) }

    func strokes(on page: GNPage) throws -> [GNStroke] {
        var out: [GNStroke] = []
        for file in page.layerFiles {
            let msgs = try ProtoFields.stream(try GoodNotesFile.read(archive, file))
            var k = 1
            while k < msgs.count {
                defer { k += 2 }
                let head = try ProtoFields(msgs[k - 1])
                if head.int(3) == 1 { continue }               // deleted
                guard let s = try ProtoFields(msgs[k]).message(7), let blob = s.bytes(2) else { continue }
                guard var path = try? GoodNotesFile.decodePath(blob), !path.lines.isEmpty else { continue }
                if let off = s.message(6) {
                    let dx = CGFloat(off.float(1) ?? 0), dy = CGFloat(off.float(2) ?? 0)
                    path.lines = path.lines.map { $0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
                }
                let c = s.message(4)
                out.append(GNStroke(color: (CGFloat(c?.float(1) ?? 0), CGFloat(c?.float(2) ?? 0),
                                            CGFloat(c?.float(3) ?? 0), CGFloat(c?.float(4) ?? 1)),
                                    width: path.width, lines: path.lines))
            }
        }
        return out
    }

    // MARK: helpers

    private static func read(_ archive: Archive, _ path: String) throws -> [UInt8] {
        guard let entry = archive[path] else { throw GoodNotesError.corrupt }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        return [UInt8](data)
    }

    /// Ink for layer X lives in notes/<X + 1>, treating the UUID as a 128-bit integer.
    static func uuidPlusOne(_ s: String) -> String {
        guard let u = UUID(uuidString: s) else { return s }
        var b = withUnsafeBytes(of: u.uuid) { Array($0) }
        for i in stride(from: 15, through: 0, by: -1) {
            b[i] &+= 1
            if b[i] != 0 { break }
        }
        let t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        return UUID(uuid: t).uuidString
    }

    struct Path { var width: CGFloat; var lines: [[CGPoint]] }

    static func decodePath(_ blob: [UInt8]) throws -> Path {
        let (sig, v) = try Tpl.decode(try BV4.decode(blob))
        var width: Float = 0
        var ops: [Int] = [], starts: [CGPoint] = [], quads: [(CGPoint, CGPoint)] = []
        func pt(_ x: TplValue, _ y: TplValue) -> CGPoint { CGPoint(x: CGFloat(x.floatValue), y: CGFloat(y.floatValue)) }

        if sig == "vuA(v)A(S(uu))A(S(uuuu))vA(f)" {
            width = v[1].floatValue
            ops = v[2].items.map(\.intValue)
            starts = v[3].items.map { pt($0.items[0], $0.items[1]) }
            quads = v[4].items.map { (pt($0.items[0], $0.items[1]), pt($0.items[2], $0.items[3])) }
        } else if sig.hasPrefix("vuA(v)A(S(uuuuu))") {
            width = v[1].floatValue
            ops = v[2].items.map(\.intValue)
            starts = v[3].items.map { pt($0.items[0], $0.items[1]) }
            quads = v[4].items.map { (pt($0.items[1], $0.items[2]), pt($0.items[6], $0.items[7])) }
        } else if sig.hasSuffix("A(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)") {
            let o = sig.hasPrefix("vu") ? 1 : 0
            width = o == 1 ? v[1].floatValue : 1
            ops = v[1 + o].items.map(\.intValue)
            let st = v[2 + o].items, qd = v[3 + o].items
            starts = stride(from: 0, to: st.count - 1, by: 2).map { pt(st[$0], st[$0 + 1]) }
            quads = stride(from: 0, to: qd.count - 3, by: 4).map { (pt(qd[$0], qd[$0 + 1]), pt(qd[$0 + 2], qd[$0 + 3])) }
        } else {
            throw GoodNotesError.unsupported(sig)
        }

        // Flatten quadratic Béziers.
        var lines: [[CGPoint]] = [], si = 0, qi = 0
        for op in ops {
            if op == 0 {
                guard si < starts.count else { break }
                lines.append([starts[si]]); si += 1
            } else {
                guard qi < quads.count, var cur = lines.popLast(), let p0 = cur.last else { break }
                let (c, e) = quads[qi]; qi += 1
                for step in 1...4 {
                    let t = CGFloat(step) / 4, a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, d = t * t
                    cur.append(CGPoint(x: a * p0.x + b * c.x + d * e.x, y: a * p0.y + b * c.y + d * e.y))
                }
                lines.append(cur)
            }
        }
        return Path(width: CGFloat(width), lines: lines.filter { !$0.isEmpty })
    }
}
