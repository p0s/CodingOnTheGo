import AppState
import AVFoundation
import FeatureComposer
import Observation
import Speech

@MainActor
@Observable
final class VoiceComposerController {
    enum RecordingState: Equatable {
        case idle
        case requestingPermission
        case recording
        case failed(String)
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var liveTranscript = ""

    var recordingState: RecordingState = .idle

    var isRecording: Bool {
        recordingState == .recording
    }

    var statusText: String? {
        switch recordingState {
        case .idle:
            nil
        case .requestingPermission:
            "Requesting speech and microphone permission."
        case .recording:
            liveTranscript.isEmpty ? "Listening…" : liveTranscript
        case let .failed(summary):
            summary
        }
    }

    func refreshAvailability(hostSupportsVoice: Bool) async -> VoiceInputAvailability {
        guard hostSupportsVoice else {
            return .unavailable
        }

        guard recognizer != nil else {
            return .unavailable
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            return await microphonePermissionGranted() ? .available : .permissionRequired
        case .notDetermined:
            return .permissionRequired
        case .denied, .restricted:
            return .permissionRequired
        @unknown default:
            return .permissionRequired
        }
    }

    func toggleRecording(onTranscript: @escaping @MainActor (String) -> Void) async -> VoiceInputAvailability {
        if isRecording {
            stopRecording(commit: true, onTranscript: onTranscript)
            return .available
        }

        recordingState = .requestingPermission

        guard recognizer != nil else {
            recordingState = .failed("Speech recognition is unavailable on this device.")
            return .unavailable
        }

        let speechAuthorized = await speechPermissionGranted()
        let microphoneAuthorized = await microphonePermissionGranted()
        guard speechAuthorized, microphoneAuthorized else {
            recordingState = .failed("Voice input needs speech recognition and microphone access.")
            return .permissionRequired
        }

        do {
            try startRecording()
            return .available
        } catch {
            recordingState = .failed(error.localizedDescription)
            stopRecording(commit: false, onTranscript: onTranscript)
            return .unavailable
        }
    }

    func stopRecording(commit: Bool, onTranscript: @escaping @MainActor (String) -> Void) {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionTask = nil
        recognitionRequest = nil

        let finalTranscript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = ""

        if commit, !finalTranscript.isEmpty {
            onTranscript(finalTranscript)
        }

        if case .failed = recordingState {
            return
        }
        recordingState = .idle
    }

    private func startRecording() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        liveTranscript = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        recordingState = .recording

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.liveTranscript = result.bestTranscription.formattedString
                }
            }

            if let error {
                Task { @MainActor in
                    self.recordingState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func speechPermissionGranted() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func microphonePermissionGranted() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
