import AVFoundation
import Speech

/// Push-to-talk for the pet: microphone → on-device speech recognition (Russian works on this Mac
/// through SFSpeechRecognizer; the newer SpeechTranscriber doesn't speak it yet). Audio never leaves the Mac.
@MainActor
final class PetVoice: ObservableObject {
    enum Failure: LocalizedError {
        case micDenied, speechDenied, unavailable
        var errorDescription: String? {
            switch self {
            case .micDenied: return "Нет доступа к микрофону — разреши его NotchIsland в Системных настройках → Конфиденциальность → Микрофон"
            case .speechDenied: return "Нет доступа к распознаванию речи — разреши его в Системных настройках → Конфиденциальность → Распознавание речи"
            case .unavailable: return "Распознавание русской речи на этом Mac недоступно"
            }
        }
    }

    @Published private(set) var isListening = false
    /// macOS is showing its microphone / speech permission dialog (the panel must not close meanwhile).
    private(set) var askingPermission = false
    /// 0…1, for the waveform next to the pet.
    @Published private(set) var level: Double = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru_RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finished: CheckedContinuation<String, Never>?
    private var limit: DispatchWorkItem?
    /// Live text while you speak.
    var onText: ((String) -> Void)?

    func start() async throws {
        guard !isListening else { return }
        askingPermission = true
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let status = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        askingPermission = false
        guard mic else { throw Failure.micDenied }
        guard status == .authorized else { throw Failure.speechDenied }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        self.request = request
        transcript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            DispatchQueue.main.async { self?.level = level }
        }
        engine.prepare()
        try engine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let text { self.transcript = text; self.onText?(text) }
                if done { self.finish() }
            }
        }
        // A forgotten key shouldn't keep the microphone on.
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in _ = await self?.stop() } }
        limit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// Stops listening and returns the final text (waits briefly for the recognizer to finish).
    func stop() async -> String {
        guard isListening else { return transcript }
        limit?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false
        level = 0
        return await withCheckedContinuation { cont in
            finished = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
        }
    }

    func cancel() {
        task?.cancel()
        if isListening {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            isListening = false
            level = 0
        }
        finish()
    }

    private func finish() {
        guard let cont = finished else { return }
        finished = nil
        task = nil
        request = nil
        cont.resume(returning: transcript)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Speech sits around 0.01–0.2: map it to 0…1 on a log scale.
        return Double(max(0, min(1, (20 * log10(max(rms, 1e-5)) + 50) / 40)))
    }
}
