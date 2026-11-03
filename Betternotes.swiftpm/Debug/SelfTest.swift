import PencilKit
import UIKit

/// Automated end-to-end checks, run in the iPad simulator on CI (`-selftest` launch argument).
/// Prints `SELFTEST PASS|FAIL <name> <detail>` lines and `SELFTEST DONE passed/total`, then exits.
@MainActor
enum SelfTest {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-selftest") }

    private static var passed = 0, total = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { passed += 1 }
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(name) \(ok ? "" : detail())")
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    static func line(_ from: CGPoint, _ to: CGPoint, width: CGFloat = 3, n: Int = 20) -> PKStroke {
        let pts = (0...n).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(n)
            return PKStrokePoint(location: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                                 timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    static func polyline(_ pts: [CGPoint], width: CGFloat = 3) -> PKStroke {
        let p = pts.enumerated().map { i, l in
            PKStrokePoint(location: l, timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: p, creationDate: Date()))
    }

    private static func findScrollView(_ v: UIView?) -> DocumentScrollView? {
        guard let v else { return nil }
        if let s = v as? DocumentScrollView { return s }
        for sub in v.subviews { if let s = findScrollView(sub) { return s } }
        return nil
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    // MARK: Run

    static func run(store: DocumentStore, open: @escaping (UUID?) -> Void) async {
        print("SELFTEST START")
        await wait(2)
        unitTests()

        // Notebook with known ink (page coordinates)
        let doc = store.create(title: "Selbsttest \(Int(Date().timeIntervalSince1970))", template: .dotted)
        let page = doc.pages[0]
        let original = PKDrawing(strokes: [line(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
                                           line(CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 600)),
                                           line(CGPoint(x: 900, y: 1400), CGPoint(x: 1000, y: 1450))])
        store.saveDrawing(original, for: page, in: doc)
        let reloaded = store.drawing(for: page, in: doc)
        check("store-roundtrip", reloaded.strokes.count == 3 && close(reloaded.bounds, original.bounds),
              "\(reloaded.strokes.count) \(reloaded.bounds) vs \(original.bounds)")

        open(doc.id)
        await wait(2.5)
        print("SELFTEST SCREENSHOT editor")
        await wait(1.5)

        guard let sv = findScrollView(window) else {
            check("editor-open", false, "no DocumentScrollView")
            return finish()
        }
        check("editor-open", true)

        func pageInk() -> PKDrawing? { sv.pageView(for: page.id)?.pageDrawing }
        func expectUnchanged(_ name: String, _ expected: PKDrawing) {
            let shown = pageInk()
            let saved = store.layerDrawing(page.id, in: store.document(doc.id) ?? doc)
            check(name + "-view", shown.map { close($0.bounds, expected.bounds) && $0.strokes.count == expected.strokes.count } ?? false,
                  "view \(String(describing: shown?.bounds)) expected \(expected.bounds)")
            check(name + "-saved", close(saved.bounds, expected.bounds) && saved.strokes.count == expected.strokes.count,
                  "saved \(saved.bounds) n=\(saved.strokes.count) expected \(expected.bounds) n=\(expected.strokes.count)")
        }
        expectUnchanged("initial", original)

        // Zoom in (pinch) and commit
        sv.setZoomScale(2, animated: false)
        sv.scrollViewDidEndZooming(sv, with: nil, atScale: 2)
        await wait(1)
        expectUnchanged("after-zoom", original)

        // Sidebar open/close: width changes in several animation steps
        let w0 = sv.frame.width
        for step in 1...6 {
            sv.frame.size.width = w0 - CGFloat(step) * 30
            sv.layoutIfNeeded()
            await wait(0.03)
        }
        await wait(0.8)
        expectUnchanged("after-narrow", original)
        for step in (0...5).reversed() {
            sv.frame.size.width = w0 - CGFloat(step) * 30
            sv.layoutIfNeeded()
            await wait(0.03)
        }
        await wait(0.8)
        expectUnchanged("after-widen", original)

        // A new stroke "written" on screen gets saved in page coordinates
        if let pv = sv.pageView(for: page.id) {
            var d = pv.canvas.drawing
            let viewStroke = line(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 90))
            d.strokes.append(viewStroke)
            pv.canvas.drawing = d
            await wait(0.8)
            let saved = store.layerDrawing(page.id, in: store.document(doc.id) ?? doc)
            check("new-stroke-saved", saved.strokes.count == 4, "n=\(saved.strokes.count)")
            let expected = saved
            // zoom back out and resize again: nothing may move
            sv.setZoomScale(0.5, animated: false)
            sv.scrollViewDidEndZooming(sv, with: nil, atScale: 0.5)
            await wait(1)
            sv.frame.size.width = w0 - 170
            sv.layoutIfNeeded()
            await wait(0.5)
            sv.frame.size.width = w0
            sv.layoutIfNeeded()
            await wait(1)
            expectUnchanged("after-new-stroke-resize", expected)
        } else {
            check("new-stroke-saved", false, "no page view")
        }

        // PDF export
        if let d = store.document(doc.id) {
            let url = try? PDFExporter.export(d, store: store, includeMarginNotes: true)
            check("pdf-export", url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }

        print("SELFTEST SCREENSHOT end")
        await wait(1.5)
        store.delete(store.document(doc.id) ?? doc)
        finish()
    }

    private static func finish() {
        print("SELFTEST DONE \(passed)/\(total)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(passed == total ? 0 : 1) }
    }

    // MARK: Pure logic

    private static func unitTests() {
        // Rectangle → 4 sharp corners, closed
        var rect: [CGPoint] = []
        for i in 0...20 { rect.append(CGPoint(x: 100 + CGFloat(i) * 15, y: 100 + CGFloat(i % 2))) }
        for i in 0...20 { rect.append(CGPoint(x: 400 + CGFloat(i % 2), y: 100 + CGFloat(i) * 10)) }
        for i in 0...20 { rect.append(CGPoint(x: 400 - CGFloat(i) * 15, y: 300 - CGFloat(i % 2))) }
        for i in 0...20 { rect.append(CGPoint(x: 100, y: 300 - CGFloat(i) * 10)) }
        let r = ShapeRecognizer.shape(from: polyline(rect), strict: true)
        check("shape-rectangle", r != nil, "nil")
        if let r { check("shape-rectangle-box", close(r.renderBounds.insetBy(dx: 2, dy: 2), CGRect(x: 100, y: 100, width: 300, height: 200), 12), "\(r.renderBounds)") }

        // Circle → round shape
        let circle = (0...72).map { i -> CGPoint in
            let a = CGFloat(i) / 72 * 2 * .pi
            return CGPoint(x: 300 + 100 * cos(a) + CGFloat(i % 3), y: 300 + 100 * sin(a))
        }
        check("shape-circle", ShapeRecognizer.shape(from: polyline(circle), strict: true) != nil)

        // Handwriting-like squiggle must stay handwriting when held
        let squiggle = (0...60).map { i -> CGPoint in
            CGPoint(x: 100 + CGFloat(i) * 2, y: 100 + 12 * sin(CGFloat(i) / 3) + CGFloat(i % 4) * 3)
        }
        check("shape-handwriting-kept", ShapeRecognizer.shape(from: polyline(squiggle), strict: true) == nil)

        // Tiny stroke must never become a shape when held
        check("shape-tiny-kept", ShapeRecognizer.shape(from: line(CGPoint(x: 10, y: 10), CGPoint(x: 25, y: 12)), strict: true) == nil)

        // Smoothing keeps points, end points and roughly the bounds
        let wobbly = polyline((0...40).map { CGPoint(x: CGFloat($0) * 5, y: 100 + CGFloat($0 % 2) * 4) })
        if let s = ShapeRecognizer.smoothed(wobbly) {
            check("smooth-count", s.path.count == wobbly.path.count)
            check("smooth-ends", s.path.first?.location == wobbly.path.first?.location && s.path.last?.location == wobbly.path.last?.location)
            check("smooth-flatter", s.renderBounds.height < wobbly.renderBounds.height, "\(s.renderBounds.height) vs \(wobbly.renderBounds.height)")
        } else {
            check("smooth", false, "nil")
        }

        // Straight-line auto straighten
        let almost = polyline((0...30).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 100 + CGFloat($0 % 2)) })
        check("straighten-line", ShapeRecognizer.straightLine(from: almost) != nil)
    }
}
