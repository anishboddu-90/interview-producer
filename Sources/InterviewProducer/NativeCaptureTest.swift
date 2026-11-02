import Foundation
import AVFoundation

@MainActor enum NativeCaptureTest {
    static func run() async -> Int32 {
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else {
            print("NATIVE CAPTURE UNVERIFIED: microphone permission is not already authorized for this build. No permission settings were changed."); return 2
        }
        let capture = AudioCaptureManager(); let frames = RehearsalChunks()
        capture.onAudioBuffer = { buffer,source in
            frames.append(.init(speaker:source,start:0,end:Double(buffer.frameLength)/16000,samples:[]))
        }
        do {
            try await capture.startCapture()
            print("Native capture started. selectedMic=\(capture.inputDeviceName), output=\(capture.outputDeviceName), micActive=\(capture.micActive). LOCAL ONLY: no transcription/model/network processing of microphone audio."); fflush(stdout)
            try await Task.sleep(for:.seconds(3))
            let micActive = capture.micActive
            await capture.stopCapture(); capture.onAudioBuffer = nil
            print("Native capture stopped. callbacks=\(frames.count), channels=\(frames.speakers.map(\.rawValue).sorted()).")
            var readableTracks = 0
            for url in [capture.systemAudioURL,capture.micAudioURL].compactMap({$0}) {
                if FileManager.default.fileExists(atPath:url.path) {
                    let file = try AVAudioFile(forReading:url)
                    print("Native \(url.lastPathComponent) finalized: \(file.length) frames at \(file.fileFormat.sampleRate) Hz.")
                    if file.length > 16000 { readableTracks += 1 }
                    // Only the newly created diagnostic tracks are removed, never an existing interview.
                    try FileManager.default.removeItem(at:url)
                }
            }
            guard micActive, frames.speakers == Set(AudioSource.allCases), readableTracks == 2 else { print("NATIVE CAPTURE FAILED: both flowing channels and readable tracks are required; an active-engine flag alone is insufficient."); return 1 }
            print("PASS: native startup/stop survived without a crash. An audible two-speaker Zoom call was not tested."); return 0
        } catch {
            await capture.stopCapture(); capture.onAudioBuffer = nil
            for url in [capture.systemAudioURL,capture.micAudioURL].compactMap({$0}) {
                try? FileManager.default.removeItem(at:url)
            }
            print("NATIVE CAPTURE UNVERIFIED: \(error.localizedDescription). No audio was sent to a provider."); return 2
        }
    }
}
