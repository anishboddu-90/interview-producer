import SwiftUI

@main struct InterviewProducerMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { Task { @MainActor in
            let portability = await GeneralizationTests.run(); let core = await ProducerTests.run(); let memory = await MemoryTests.run(); let story = await StoryTests.run(); let lifeline = await LifelineTests.run(); let integration = await IntegrationTests.run(); exit(portability == 0 && core == 0 && memory == 0 && story == 0 && lifeline == 0 && integration == 0 ? 0 : 1)
        }; dispatchMain() }
        if let i = CommandLine.arguments.firstIndex(of:"--zoom-speech-test"), i+1 < CommandLine.arguments.count {
            let root = URL(fileURLWithPath:CommandLine.arguments[i+1])
            Task { @MainActor in exit(await ZoomSpeechTest.run(root:root,seconds:110)) }; dispatchMain()
        }
        if CommandLine.arguments.contains("--native-capture-test") { Task { @MainActor in exit(await NativeCaptureTest.run()) }; dispatchMain() }
        if CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--full-live-rehearsal") {
            let args = CommandLine.arguments
            func url(_ flag: String) -> URL? { guard let i = args.firstIndex(of:flag), i+1 < args.count else { return nil }; return URL(fileURLWithPath:args[i+1]) }
            Task { @MainActor in exit(await IntegrationTests.run(live:args.contains("--full-live-rehearsal"),audioFolder:url("--rehearsal-audio"),artifacts:url("--rehearsal-output"))) }; dispatchMain()
        }
        if let i = CommandLine.arguments.firstIndex(of:"--import-memory-selection"), i+2 < CommandLine.arguments.count {
            let export = URL(fileURLWithPath:CommandLine.arguments[i+1]); let selection = URL(fileURLWithPath:CommandLine.arguments[i+2])
            Task { @MainActor in exit(await MemoryImportCommand.run(export:export,selection:selection)) }; dispatchMain()
        }
        if let i = CommandLine.arguments.firstIndex(of:"--import-question-profile"), i+1 < CommandLine.arguments.count {
            Task { @MainActor in
                do { let library = LifelineLibrary(); try library.importBank(URL(fileURLWithPath:CommandLine.arguments[i+1])); print("Selected personal profile: \(library.selected?.name ?? "none"); \(library.selected?.questions.count ?? 0) questions; automatic=\(library.selected?.settings.automatic ?? false)"); exit(0) }
                catch { print("Question-profile import failed: \(error.localizedDescription)"); exit(1) }
            }; dispatchMain()
        }
        if CommandLine.arguments.contains("--lifeline-live-test") { Task { @MainActor in exit(await LifelineLiveTest.run()) }; dispatchMain() }
        if CommandLine.arguments.contains("--lifeline-test") { Task { @MainActor in exit(await LifelineTests.run()) }; dispatchMain() }
        if CommandLine.arguments.contains("--story-live-test") { Task { @MainActor in exit(await StoryLiveTest.run()) }; dispatchMain() }
        if CommandLine.arguments.contains("--story-test") { Task { @MainActor in exit(await StoryTests.run()) }; dispatchMain() }
        if CommandLine.arguments.contains("--memory-live-test") { Task { @MainActor in exit(await MemoryLiveTest.run()) }; dispatchMain() }
        if CommandLine.arguments.contains("--memory-test") { Task { @MainActor in exit(await MemoryTests.run()) }; dispatchMain() }
        if let i = CommandLine.arguments.firstIndex(of:"--write-memory-demo"), i+1 < CommandLine.arguments.count {
            do { try MemoryFixtures.export().write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]),options:.atomic) } catch { print(error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--live-scenarios") { Task { @MainActor in exit(await ProducerTests.live()) }; dispatchMain() }
        if CommandLine.arguments.contains("--connect") {
            Task { @MainActor in
                do {
                    try await ChatGPTSession.shared.signIn()
                    print("Validated ChatGPT identity and plan permission.")
                    let models = try await ChatGPTSession.shared.models()
                    guard let model = models.first else { throw ProducerError.message("No eligible models available.") }
                    ProducerDefaults.shared.set(model.slug,forKey:"producer.model")
                    let output = try await ChatGPTSession.shared.complete(model:model.slug,instructions:"Reply in one short sentence.",input:"Say: Interview Producer connection verified.")
                    print("Completed real inference: \(output)"); exit(0)
                } catch { print("CONNECTION NOT VERIFIED: \(error.localizedDescription)"); exit(1) }
            }; dispatchMain()
        }
        ProducerDefaults.shared.register(defaults:["producer.sensitivity":"Balanced","producer.cooldown":35,"producer.showPanel":true,"echoCancellationEnabled":false,"producer.autoNotes":true])
        ProducerApp.main()
    }
}
@MainActor final class ProducerAppDelegate: NSObject,NSApplicationDelegate {
    weak var controller: InterviewController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        controller.flushQuestionsBeforeClose(); controller.questionShortcut.unregister()
        guard controller.isStarting || controller.isRecording || controller.isStopping else { return .terminateNow }
        Task { await controller.stop(); while controller.isStopping { try? await Task.sleep(for:.milliseconds(100)) }; controller.flushQuestionsBeforeClose(); sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}
struct ProducerApp: App {
    @NSApplicationDelegateAdaptor(ProducerAppDelegate.self) private var delegate
    @State private var controller = InterviewController()
    var body: some Scene {
        WindowGroup("Interview Producer") {
            ProducerWorkspace().environment(controller).onAppear { delegate.controller = controller; controller.configureQuestionShortcut() }
        }.defaultSize(width:1080,height:780)
        .commands {
            CommandGroup(after:.newItem) {
                Button("Dismiss suggestion") { controller.action("dismissed") }.keyboardShortcut(.escape,modifiers:[])
                Button("Save suggestion") { controller.action("saved") }.keyboardShortcut("s",modifiers:[.command,.shift])
                Button("Next Question") { controller.nextQuestion() }
                Button("Stop capture") { Task { await controller.stop() } }.keyboardShortcut(".",modifiers:.command)
            }
        }
        MenuBarExtra {
            Text(controller.isRecording ? "Recording · both tracks" : "Not recording")
            Button("Next Question") { controller.nextQuestion() }
            Button("Stop capture now") { Task { await controller.stop() } }.disabled(!controller.isRecording)
            Button(controller.alertsMuted ? "Resume analysis" : "Mute analysis") { controller.toggleMute() }
        } label: { Label(controller.isRecording ? "REC" : "Producer",systemImage:controller.isRecording ? "record.circle.fill" : "waveform") }
        Settings { ProducerConnectionView().environment(controller).frame(width:650,height:730) }
    }
}
