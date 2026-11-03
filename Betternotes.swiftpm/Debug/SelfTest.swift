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

        await lassoAndPasteTests(store: store, docID: doc.id, sv: sv, pageID: page.id, w0: w0)

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

    // MARK: Lasso, camera lasso, copy/paste, photos, text

    private static func lassoAndPasteTests(store: DocumentStore, docID: UUID, sv: DocumentScrollView,
                                           pageID: UUID, w0: CGFloat) async {
        guard let pv = sv.pageView(for: pageID), let doc0 = store.document(docID) else {
            check("lasso-setup", false, "no page view")
            return
        }
        func saved() -> PKDrawing { store.layerDrawing(pageID, in: store.document(docID) ?? doc0) }
        func page() -> NotePage? { store.document(docID)?.pages.first { $0.id == pageID } }
        let unit = pv.testViewRect(CGRect(x: 0, y: 0, width: 100, height: 100)).width / 100   // points per page unit

        // 1. Lasso selects exactly the top line (page 100…500, y 100)
        let topLine = pv.testViewRect(CGRect(x: 80, y: 80, width: 440, height: 40))
        pv.testLasso(topLine)
        check("lasso-select", pv.testSelectedStrokeCount == 1, "selected \(pv.testSelectedStrokeCount)")

        // 2. Move by 50/40 screen points → saved stroke moved by the same page distance
        let before = saved()
        pv.testMoveSelection(by: CGPoint(x: 50, y: 40))
        await wait(0.4)
        let afterMove = saved()
        let moved = afterMove.strokes.contains { abs($0.renderBounds.minX - (before.strokes[0].renderBounds.minX + 50 / unit)) < 3
                                                 && abs($0.renderBounds.minY - (before.strokes[0].renderBounds.minY + 40 / unit)) < 3 }
        check("lasso-move-saved", moved && afterMove.strokes.count == before.strokes.count,
              "n=\(afterMove.strokes.count) bounds=\(afterMove.strokes.map(\.renderBounds))")

        // 3. Resize ×1.5
        let w1 = pv.testSelectionRect.width
        pv.testScaleSelection(1.5)
        await wait(0.3)
        check("lasso-resize", abs(pv.testSelectionRect.width - (w1 - 16) * 1.5 - 16) < 6,
              "\(w1) → \(pv.testSelectionRect.width)")

        // 4. Recolour red
        pv.testRecolorSelection(.systemRed)
        await wait(0.3)
        let red = saved().strokes.filter { $0.ink.color.cgColor.components?.first ?? 0 > 0.8 }
        check("lasso-recolor", red.count == 1, "red strokes \(red.count)")

        // 5. Duplicate → one more stroke, copy stays selected
        let n0 = saved().strokes.count
        pv.testDuplicateSelection()
        await wait(0.3)
        check("lasso-duplicate", saved().strokes.count == n0 + 1 && pv.testSelectedStrokeCount == 1,
              "n=\(saved().strokes.count) sel=\(pv.testSelectedStrokeCount)")

        // 6. Copy + paste elsewhere → editable strokes again
        pv.testCopySelection()
        check("copy-strokes-on-pasteboard",
              UIPasteboard.general.contains(pasteboardTypes: [PageCanvasView.strokesPasteboardType]))
        let n1 = saved().strokes.count
        pv.testPaste(at: pv.testViewRect(CGRect(x: 200, y: 900, width: 1, height: 1)).origin)
        await wait(0.4)
        check("paste-strokes", saved().strokes.count == n1 + 1, "n=\(saved().strokes.count) expected \(n1 + 1)")

        // 7. Cut → stroke gone, still on pasteboard
        let n2 = saved().strokes.count
        pv.testCutSelection()
        await wait(0.3)
        check("lasso-cut", saved().strokes.count == n2 - 1 && pv.testSelectedStrokeCount == 0, "n=\(saved().strokes.count)")

        // 8. Lasso + delete
        pv.testLasso(pv.testViewRect(CGRect(x: 880, y: 1380, width: 140, height: 90)))
        let n3 = saved().strokes.count
        pv.testDeleteSelection()
        await wait(0.3)
        check("lasso-delete", saved().strokes.count == n3 - 1, "n=\(saved().strokes.count) from \(n3)")

        // 9. Camera lasso → picture of the circled area's bounding box on the pasteboard
        UIPasteboard.general.items = []
        let camRect = pv.testViewRect(CGRect(x: 80, y: 250, width: 400, height: 400))
        pv.testCameraLasso(camRect)
        await wait(0.6)
        if let img = UIPasteboard.general.image {
            check("camera-lasso-image", abs(img.size.width - camRect.width) < 3 && abs(img.size.height - camRect.height) < 3,
                  "image \(img.size) rect \(camRect.size)")
        } else {
            check("camera-lasso-image", false, "no image on pasteboard")
        }

        // 9b. …and that picture can be pasted onto the page (button in the hint) and is not blank
        let camImages0 = page()?.images.count ?? 0
        pv.pasteFromClipboard()
        await wait(0.6)
        let camImages = page()?.images ?? []
        check("camera-lasso-paste", camImages.count == camImages0 + 1, "images \(camImages.count)")
        if let item = camImages.last, let d = store.document(docID),
           let img = UIImage(contentsOfFile: store.attachmentURL(item.file, in: d).path) {
            check("camera-lasso-has-ink", !isBlank(img), "pasted picture is blank/white")
        }

        // 10. Paste a photo → image item on the page
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        UIPasteboard.general.image = photo
        let images0 = page()?.images.count ?? 0
        pv.testPaste(at: pv.testViewRect(CGRect(x: 300, y: 700, width: 1, height: 1)).origin)
        await wait(0.6)
        let images1 = page()?.images ?? []
        check("paste-photo", images1.count == images0 + 1, "images \(images1.count)")

        if let img = images1.last, let pv2 = sv.pageView(for: pageID) {
            // 11. Select photo, move, resize (keeps aspect), bring to front
            pv2.selectObject(img.id)
            check("photo-select", pv2.testSelectedObject == img.id)
            pv2.moveSelectedObject(by: CGPoint(x: 30, y: 20), commit: true)
            await wait(0.4)
            let movedImg = page()?.images.first { $0.id == img.id }
            check("photo-move-saved", movedImg.map { abs($0.frame.minX - (img.frame.minX + 30 / unit)) < 2
                                                     && abs($0.frame.minY - (img.frame.minY + 20 / unit)) < 2 } ?? false,
                  "\(String(describing: movedImg?.frame)) from \(img.frame)")
            pv2.resizeSelectedObject(by: CGPoint(x: 40, y: 0), commit: true)
            await wait(0.4)
            if let r = page()?.images.first(where: { $0.id == img.id }) {
                check("photo-resize", r.frame.width > img.frame.width + 30 / unit, "\(r.frame.width) vs \(img.frame.width)")
                check("photo-aspect", abs(r.frame.height / r.frame.width - img.frame.height / img.frame.width) < 0.01)
            }
            pv2.testBringToFront(img.id)
            await wait(0.3)
            check("photo-front", page()?.images.last?.id == img.id)
            pv2.deselectObject()
        }

        // 12. Paste text → text box; select it, bigger font
        UIPasteboard.general.string = "Hallo Betternotes"
        let texts0 = page()?.textBoxes.count ?? 0
        if let pv3 = sv.pageView(for: pageID) {
            pv3.testPaste(at: pv3.testViewRect(CGRect(x: 120, y: 1100, width: 1, height: 1)).origin)
            await wait(0.5)
            let texts = page()?.textBoxes ?? []
            check("paste-text", texts.count == texts0 + 1 && texts.last?.text == "Hallo Betternotes", "texts \(texts.count)")
            if let tb = texts.last {
                pv3.selectObject(tb.id)
                pv3.testScaleFont(tb.id, by: 1.3)
                await wait(0.4)
                let size = page()?.textBoxes.first { $0.id == tb.id }?.fontSize ?? 0
                check("text-font-bigger", size > tb.fontSize * 1.2, "\(size) vs \(tb.fontSize)")
                pv3.deselectObject()
            }
        }

        // 13. After all edits: resize the view again – saved ink and view must still agree
        let finalInk = saved()
        sv.frame.size.width = w0 - 170
        sv.layoutIfNeeded()
        await wait(0.5)
        sv.frame.size.width = w0
        sv.layoutIfNeeded()
        await wait(1)
        let shown = sv.pageView(for: pageID)?.pageDrawing
        check("final-consistent", shown.map { close($0.bounds, finalInk.bounds) && $0.strokes.count == finalInk.strokes.count } ?? false,
              "view \(String(describing: shown?.bounds)) saved \(finalInk.bounds)")
        check("final-saved-stable", close(saved().bounds, finalInk.bounds) && saved().strokes.count == finalInk.strokes.count)
        print("SELFTEST SCREENSHOT edits")
        await wait(1.5)
    }

    /// True if the picture is (almost) a single colour – e.g. a snapshot that missed the ink.
    private static func isBlank(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage else { return true }
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r: Int = Int(px[i])
            let g: Int = Int(px[i + 1])
            let b: Int = Int(px[i + 2])
            if r + g + b < 300 { dark += 1 }
        }
        return dark < 5
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
            // jitter of the control points must shrink (render bounds include the pen width, so use points)
            func spread(_ st: PKStroke) -> CGFloat {
                let ys = st.path.dropFirst().dropLast().map(\.location.y)
                return (ys.max() ?? 0) - (ys.min() ?? 0)
            }
            check("smooth-flatter", spread(s) < spread(wobbly) * 0.7, "\(spread(s)) vs \(spread(wobbly))")
        } else {
            check("smooth", false, "nil")
        }

        // Straight-line auto straighten
        let almost = polyline((0...30).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 100 + CGFloat($0 % 2)) })
        check("straighten-line", ShapeRecognizer.straightLine(from: almost) != nil)
    }
}
