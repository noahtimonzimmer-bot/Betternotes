import SwiftUI
import UIKit

/// Transparent view that receives Apple Pencil double-tap and (Pencil Pro) squeeze.
struct PencilGestureView: UIViewRepresentable {
    let tools: ToolController

    func makeCoordinator() -> Coordinator { Coordinator(tools: tools) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        v.addInteraction(interaction)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        let tools: ToolController
        init(tools: ToolController) { self.tools = tools }

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
}

@available(iOS 17.5, *)
extension PencilGestureView.Coordinator {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        var action = tools.settings.doubleTap
        if action == .system { action = tools.systemAction(UIPencilInteraction.preferredTapAction) }
        tools.perform(action, at: tap.hoverPose?.location)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        var action = tools.settings.squeeze
        if action == .system { action = tools.systemAction(UIPencilInteraction.preferredSqueezeAction) }
        tools.perform(action, at: squeeze.hoverPose?.location)
    }
}
