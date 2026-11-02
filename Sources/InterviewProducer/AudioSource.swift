import Foundation
// Parrot's capture callbacks use physical channels; these labels remain separate throughout transcription.
enum AudioSource: String, CaseIterable, Codable, Sendable {
    case me, them
    static let mic = AudioSource.me
    static let system = AudioSource.them
    var label: String { self == .me ? "Interviewer" : "Interviewee" }
}
