import SwiftUI

/// What a Pencil gesture (double-tap or squeeze) does. All configurable in Settings.
enum PencilAction: String, CaseIterable, Identifiable {
    case system          // follow iPadOS setting (Settings › Apple Pencil)
    case toolPalette     // show tool/colour palette at the pencil tip
    case temporaryEraser // eraser for one gesture, then back to previous tool
    case toggleEraser    // eraser until gesture again
    case previousTool
    case lasso
    case none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Wie in iPadOS-Einstellungen"
        case .toolPalette: return "Werkzeugauswahl anzeigen"
        case .temporaryEraser: return "Radierer (einmal, dann zurück)"
        case .toggleEraser: return "Radierer ein/aus"
        case .previousTool: return "Vorheriges Werkzeug"
        case .lasso: return "Lasso"
        case .none: return "Nichts"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var doubleTap: PencilAction { didSet { d.set(doubleTap.rawValue, forKey: "pencil.doubleTap") } }
    @Published var squeeze: PencilAction { didSet { d.set(squeeze.rawValue, forKey: "pencil.squeeze") } }
    @Published var onlyPencilDraws: Bool { didSet { d.set(onlyPencilDraws, forKey: "pencil.onlyPencilDraws") } }
    @Published var eraserWholeStroke: Bool { didSet { d.set(eraserWholeStroke, forKey: "eraser.wholeStroke") } }
    /// Extra writing space left and right of each page, as a fraction of the page width.
    @Published var marginRatio: Double { didSet { d.set(marginRatio, forKey: "page.margin") } }
    @Published var straightenLines: Bool { didSet { d.set(straightenLines, forKey: "ink.straighten") } }

    init() {
        d.register(defaults: [
            "pencil.doubleTap": PencilAction.temporaryEraser.rawValue,
            "pencil.squeeze": PencilAction.toolPalette.rawValue,
            "pencil.onlyPencilDraws": true,
            "eraser.wholeStroke": true,
            "page.margin": 0.35,
            "ink.straighten": true,
        ])
        doubleTap = PencilAction(rawValue: d.string(forKey: "pencil.doubleTap") ?? "") ?? .temporaryEraser
        squeeze = PencilAction(rawValue: d.string(forKey: "pencil.squeeze") ?? "") ?? .toolPalette
        onlyPencilDraws = d.bool(forKey: "pencil.onlyPencilDraws")
        eraserWholeStroke = d.bool(forKey: "eraser.wholeStroke")
        marginRatio = d.double(forKey: "page.margin")
        straightenLines = d.bool(forKey: "ink.straighten")
    }
}
