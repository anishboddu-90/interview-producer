import SwiftUI
import AppKit

@MainActor final class ProducerPanel {
    static let shared = ProducerPanel()
    private var panel: NSPanel?
    func show(_ suggestion: SavedSuggestion,controller: InterviewController) {
        showControls(controller:controller)
    }
    func showControls(controller: InterviewController) {
        guard ProducerDefaults.shared.object(forKey:"producer.showPanel") as? Bool ?? true else { return }
        let p: NSPanel
        if let panel { p = panel } else {
            p = NSPanel(contentRect:NSRect(x:0,y:0,width:370,height:260),styleMask:[.nonactivatingPanel,.titled,.closable,.resizable],backing:.buffered,defer:false)
            p.title = "Interview Producer · private"
            p.level = .floating; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            p.sharingType = .none; p.isReleasedWhenClosed = false
            if let screen = NSScreen.main { p.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-390,y:screen.visibleFrame.maxY-300)) }
            panel = p
        }
        p.contentView = NSHostingView(rootView:ScrollView { ProducerOverlay(controller:controller).padding(18) })
        p.orderFrontRegardless() // never makeKey or activate: Zoom retains keyboard focus.
    }
    func hide() { panel?.orderOut(nil) }
}

struct ProducerOverlay: View {
    var controller: InterviewController
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if let followup = controller.activeSuggestion { SuggestionCard(suggestion:followup,controller:controller) }
            else if let lifeline = controller.activeLifeline { LifelineCard(card:lifeline,controller:controller) }
            else { Text("Listening · questions stay private").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Button(controller.lifelineBusy ? "Choosing next question…" : "Next Question") { controller.nextQuestion() }
                .buttonStyle(.borderedProminent).disabled(controller.lifelineBusy || controller.activeSuggestion != nil)
            Text(controller.questionShortcut.status).font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("All Questions") { LifelineRemainingQuestions(controller:controller) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct SuggestionCard: View {
    var suggestion: SavedSuggestion
    var controller: InterviewController
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(suggestion.decision.priority == "high" ? "HIGH-PRIORITY FOLLOW-UP" : "EDITORIAL FOLLOW-UP",systemImage:"sparkle")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text(suggestion.decision.suggested_question).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(suggestion.decision.reason).font(.callout).foregroundStyle(.secondary).lineLimit(5)
            SuggestionEvidenceView(suggestion:suggestion)
            HStack {
                Button("Asked") { controller.action("asked") }
                Button("Save") { controller.action("saved") }
                Button("Dismiss") { controller.action("dismissed") }
            }.buttonStyle(.bordered)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
