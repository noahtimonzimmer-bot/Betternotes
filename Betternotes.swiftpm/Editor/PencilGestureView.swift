import UIKit

/// Receives Apple Pencil double-tap and (Pencil Pro) squeeze for the view it is attached to.
@MainActor
final class PencilGestureHandler: NSObject, UIPencilInteractionDelegate {
    let tools: ToolController
    init(tools: ToolController) { self.tools = tools }

    func attach(to view: UIView) {
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
    }

    /// Hover locations come in the view's bounds space; for a scroll view that includes the offset.
    fileprivate func visible(_ p: CGPoint?, in view: UIView?) -> CGPoint? {
        guard let p, let view else { return nil }
        return CGPoint(x: p.x - view.bounds.minX, y: p.y - view.bounds.minY)
    }

    // iPadOS < 17.5
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        var action = tools.settings.doubleTap
        if action == .system {
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser: action = .toggleEraser
            case .switchPrevious: action = .previousTool
            case .showColorPalette: action = .toolPalette
            default: action = .none
            }
        }
        tools.perform(action, at: nil)
    }
}

@available(iOS 17.5, *)
extension PencilGestureHandler {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        var action = tools.settings.doubleTap
        if action == .system { action = tools.systemAction(UIPencilInteraction.preferredTapAction) }
        tools.perform(action, at: visible(tap.hoverPose?.location, in: interaction.view))
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        var action = tools.settings.squeeze
        if action == .system { action = tools.systemAction(UIPencilInteraction.preferredSqueezeAction) }
        tools.perform(action, at: visible(squeeze.hoverPose?.location, in: interaction.view))
    }
}
