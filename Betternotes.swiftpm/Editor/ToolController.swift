import PencilKit
import SwiftUI

/// Current tool for all pages of an open notebook, plus Pencil gesture handling.
@MainActor
final class ToolController: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case pen, pencil, marker, eraser, shape, lasso, cameraLasso, text
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .pencil: return "pencil"
            case .marker: return "highlighter"
            case .eraser: return "eraser"
            case .shape: return "square.on.circle"
            case .lasso: return "lasso"
            case .cameraLasso: return "camera.viewfinder"
            case .text: return "textformat"
            }
        }
        var label: String {
            switch self {
            case .pen: return "Füller"
            case .pencil: return "Bleistift"
            case .marker: return "Textmarker"
            case .eraser: return "Radierer"
            case .shape: return "Formen"
            case .lasso: return "Lasso (verschieben, Größe, Farbe, in Text)"
            case .cameraLasso: return "Kamera-Lasso"
            case .text: return "Text & Objekte"
            }
        }
        var usesColor: Bool { [.pen, .pencil, .marker, .shape].contains(self) }
    }

    static let palette: [UIColor] = [
        UIColor(red: 0.12, green: 0.11, blue: 0.11, alpha: 1),
        UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1),
        UIColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1),
        UIColor(red: 0.93, green: 0.40, blue: 0.70, alpha: 1),
        UIColor(red: 0.98, green: 0.80, blue: 0.10, alpha: 1),
        UIColor(red: 0.20, green: 0.75, blue: 0.35, alpha: 1),
    ]
    static let widths: [CGFloat] = [1.6, 2.6, 4.5]

    @Published var kind: Kind = .pen
    @Published var color: UIColor = ToolController.palette[0]
    @Published var markerColor: UIColor = ToolController.palette[4]
    @Published var width: CGFloat = 2.6
    /// Where to show the squeeze palette (editor coordinates); nil = hidden.
    @Published var paletteLocation: CGPoint?

    let settings: AppSettings
    private var previousKind: Kind = .pen
    private var kindBeforeTemporaryEraser: Kind?

    init(settings: AppSettings) { self.settings = settings }

    var tool: PKTool {
        switch kind {
        case .pen, .shape: return PKInkingTool(.pen, color: color, width: width)
        case .pencil: return PKInkingTool(.pencil, color: color, width: width * 1.5)
        case .marker: return PKInkingTool(.marker, color: markerColor, width: width * 6)
        case .eraser: return PKEraserTool(settings.eraserWholeStroke ? .vector : .bitmap)
        case .lasso, .cameraLasso, .text: return PKLassoTool()
        }
    }

    var pageMode: PageCanvasView.Mode {
        switch kind {
        case .shape: return .shape
        case .lasso: return .lasso
        case .cameraLasso: return .camera
        case .text: return .objects
        default: return .ink
        }
    }

    var currentColor: UIColor { kind == .marker ? markerColor : color }

    func setColor(_ c: UIColor) {
        if kind == .marker { markerColor = c } else { color = c }
        if !kind.usesColor { select(previousKind.usesColor ? previousKind : .pen) }
    }

    func select(_ k: Kind) {
        kindBeforeTemporaryEraser = nil
        if k != kind { previousKind = kind }
        kind = k
    }

    /// Called by a canvas when the user lifts the pencil.
    func didEndUsingTool() {
        if let k = kindBeforeTemporaryEraser {
            kindBeforeTemporaryEraser = nil
            kind = k
        }
    }

    // MARK: Pencil gestures

    func perform(_ action: PencilAction, at location: CGPoint?) {
        switch action {
        case .system, .none: break
        case .toolPalette:
            paletteLocation = paletteLocation == nil ? (location ?? CGPoint(x: 300, y: 200)) : nil
        case .temporaryEraser:
            if kind == .eraser {
                didEndUsingTool()
            } else {
                let current = kind
                select(.eraser)
                kindBeforeTemporaryEraser = current
            }
        case .toggleEraser:
            select(kind == .eraser ? previousKind : .eraser)
        case .previousTool:
            select(previousKind)
        case .lasso:
            select(kind == .lasso ? previousKind : .lasso)
        case .cameraLasso:
            select(kind == .cameraLasso ? previousKind : .cameraLasso)
        }
    }

    @available(iOS 17.5, *)
    func systemAction(_ preferred: UIPencilPreferredAction) -> PencilAction {
        switch preferred {
        case .switchEraser: return .toggleEraser
        case .switchPrevious: return .previousTool
        case .showColorPalette, .showInkAttributes, .showContextualPalette: return .toolPalette
        default: return .none
        }
    }
}
