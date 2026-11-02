import Foundation
import AVFoundation

/// The capture implementation is unchanged. A replay device can exercise the same controller/pipeline in isolation.
protocol InterviewCaptureDevice: AnyObject {
    var onAudioBuffer: ((AVAudioPCMBuffer,AudioSource) -> Void)? { get set }
    var isCapturing: Bool { get }; var micActive: Bool { get }; var micSignalLost: Bool { get }
    var micLevel: Float { get }; var audioLevel: Float { get }
    var inputDeviceName: String { get }; var outputDeviceName: String { get }
    var systemAudioURL: URL? { get }; var micAudioURL: URL? { get }
    var replayTime: Double? { get }
    @MainActor func startCapture() async throws
    @MainActor func stopCapture() async
}
extension AudioCaptureManager: InterviewCaptureDevice { var replayTime: Double? { nil } }

struct InterviewRepository {
    let root: URL?
    var directory: URL { root?.appendingPathComponent("Interviews") ?? InterviewStore.directory }
    var audioDirectory: URL { root?.appendingPathComponent("Audio") ?? AudioCaptureManager.storageDirectory() }
    func save(_ record: InterviewRecord) throws { try InterviewStore.save(record,in:directory) }
    func list() -> [InterviewRecord] { InterviewStore.list(in:directory) }
    func delete(_ record: InterviewRecord) throws { try InterviewStore.delete(record,in:directory,audioDirectory:audioDirectory) }
}

@MainActor struct InterviewDependencies {
    var audio: any InterviewCaptureDevice
    var repository: InterviewRepository
    var research: ResearchLibrary; var memory: MemoryLibrary; var stories: StoryLibrary
    var questions: LifelineLibrary
    var editorial: EditorialService; var storyEngine: StoryEngine; var lifelineEngine: LifelineEngine
    var preferences: UserDefaults
    var transcriptionReady: () -> Bool
    var microphonePermission: () async -> Bool
    var transcriber: (@Sendable (AudioChunk) async throws -> String)?
    var onChunk: (@Sendable (AudioChunk) -> Void)? = nil
    var showsPanels: Bool
    var debounce: Double = 3; var analysisInterval: Double = 12; var drainTimeout: Double = 45
    var replayDelay: Double = 2
    var isRehearsal: Bool { repository.root != nil }
    init(root: URL? = nil,audio: (any InterviewCaptureDevice)? = nil,preferences: UserDefaults? = nil,
         inference: @escaping @Sendable (String,String) async throws -> String = { try await ProducerInference.complete(instructions:$0,input:$1) },
         transcriber: (@Sendable (AudioChunk) async throws -> String)? = nil) {
        self.audio = audio ?? AudioCaptureManager(); repository = .init(root:root)
        self.preferences = preferences ?? ProducerDefaults.shared
        let archive = root.map { ConversationMemory(url:$0.appendingPathComponent("Memory.sqlite")) } ?? .shared
        memory = MemoryLibrary(store:archive)
        research = ResearchLibrary(url:root?.appendingPathComponent("research.json"),includeDefaults:root == nil)
        stories = StoryLibrary(url:root?.appendingPathComponent("story-editor.json"))
        questions = LifelineLibrary(url:root?.appendingPathComponent("questions.json"))
        editorial = EditorialService(archive:archive,inference:inference)
        storyEngine = StoryEngine(memory:archive,inference:inference)
        lifelineEngine = LifelineEngine(memory:archive,inference:inference)
        transcriptionReady = { TranscriptionProvider.ready }
        microphonePermission = { await PermissionFlow.requestMicrophone() }
        self.transcriber = transcriber; showsPanels = root == nil
    }
}
