import AVFoundation
import CoreAudio
import CoreMedia

/// An explicitly selected capture device does not follow Bluetooth's default input/output route.
/// Session startup and sample conversion stay on one serial queue, away from the UI.
// Session, converter and output mutations are confined to queue; callbacks are set before start.
final class BuiltInMicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label:"org.interviewproducer.builtin-mic")
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let target = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var errorObserver: NSObjectProtocol?

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone],mediaType:.audio,position:.unspecified).devices
                    let selected = InterviewSettings.current.microphoneID
                    let candidate = selected.isEmpty ? (devices.first(where:{UInt32(bitPattern:$0.transportType) == kAudioDeviceTransportTypeBuiltIn}) ?? AVCaptureDevice.default(for:.audio)) : devices.first(where:{$0.uniqueID == selected})
                    guard let device = candidate else { throw ProducerError.message("The selected microphone is unavailable. Choose an available device in Interview setup.") }
                    let input = try AVCaptureDeviceInput(device:device)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                        self.session.commitConfiguration(); throw ProducerError.message("Microphone capture could not be configured.")
                    }
                    self.session.addInput(input); self.session.addOutput(self.output)
                    self.output.setSampleBufferDelegate(self,queue:self.queue)
                    self.session.commitConfiguration()
                    self.errorObserver = NotificationCenter.default.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:self.session,queue:nil) { [weak self] note in
                        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                        let detail = error?.localizedDescription ?? "Microphone capture was interrupted."
                        Task { @MainActor [weak self] in self?.onFailure?(detail) }
                    }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw ProducerError.message("Microphone capture did not start.") }
                    continuation.resume(returning:device.localizedName)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let observer = self.errorObserver { NotificationCenter.default.removeObserver(observer) }; self.errorObserver = nil
                self.output.setSampleBufferDelegate(nil,queue:nil)
                self.session.stopRunning(); self.converter = nil; self.inputFormat = nil
                continuation.resume()
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription:description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, count < 1_000_000, let pcm = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,at:0,frameCount:Int32(count),into:pcm.mutableAudioBufferList) == noErr else { return }
        if inputFormat != format { inputFormat = format; converter = AVAudioConverter(from:format,to:target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(count)*16000/format.sampleRate)+32)
        guard let converted = AVAudioPCMBuffer(pcmFormat:target,frameCapacity:capacity) else { return }
        var error: NSError?; var consumed = false
        converter.convert(to:converted,error:&error) { _,status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return pcm
        }
        if error == nil, converted.frameLength > 0 { onBuffer?(converted) }
    }
}
