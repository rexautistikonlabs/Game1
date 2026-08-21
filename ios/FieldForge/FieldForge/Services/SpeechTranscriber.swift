//
//  SpeechTranscriber.swift
//  FieldForge
//
//  Dictating a visit note while walking to the next door.
//
//  On-device recognition is requested explicitly. That is the whole feature:
//  server-based transcription would mean no notes in a basement, no notes in a
//  rural county, and donor conversations leaving the phone. On-device is
//  slightly less accurate and completely private, which is the right trade for
//  "spoke to the manager, come back Thursday".
//

import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechTranscriber {

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
        case unavailable(String)
    }

    private(set) var state: State = .idle

    /// Live transcript, updated as the staffer speaks so they can see it is
    /// working. Partial results are marked so the UI can style them lightly.
    private(set) var transcript: String = ""
    private(set) var isPartial: Bool = false

    /// Rough input level, 0–1, for the level meter. A silent meter is how a
    /// staffer discovers the mic is covered by their thumb.
    private(set) var inputLevel: Double = 0

    /// True when transcription is genuinely running on this device.
    private(set) var isOnDevice: Bool = false

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Auto-stop after this long. A forgotten open mic is a battery and privacy
    /// problem, and nobody dictates a two-minute doorstep note.
    var maximumDuration: Duration = .seconds(120)
    private var timeoutTask: Task<Void, Never>?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    // MARK: Availability

    var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable
    }

    /// On-device support depends on the language and whether the model has been
    /// downloaded. When it is unavailable the UI says dictation needs a
    /// connection rather than silently sending audio to a server.
    var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: Permissions

    /// Asks for speech and microphone permission together, because being asked
    /// twice in a row for one feature feels broken.
    func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else {
            state = .unavailable("Dictation needs permission to recognise speech. Turn it on in Settings.")
            return false
        }

        let micAuthorized = await AVAudioApplication.requestRecordPermission()
        guard micAuthorized else {
            state = .unavailable("Dictation needs microphone access. Turn it on in Settings.")
            return false
        }
        return true
    }

    // MARK: Start / stop

    func start() async {
        guard state == .idle || isUnavailableState else { return }
        state = .preparing
        transcript = ""
        isPartial = false

        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Dictation is not available right now. You can still type the note.")
            return
        }

        do {
            try configureAudioSession()
        } catch {
            state = .unavailable("Could not start the microphone. \(error.localizedDescription)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The point of the whole file.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Names of businesses and people are the hard part; the hint helps.
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        isOnDevice = request.requiresOnDeviceRecognition

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            state = .unavailable("No microphone input is available.")
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.meterLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.inputLevel = level
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            state = .unavailable("Could not start recording. \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.isPartial = !result.isFinal
                    if result.isFinal { self.finishInternal() }
                }
                if error != nil {
                    // A recognition error mid-sentence still leaves whatever was
                    // transcribed so far, which is usually the useful part.
                    self.finishInternal()
                }
            }
        }

        state = .listening
        startTimeout()
        AppLog.capture.info("Dictation started (onDevice: \(self.isOnDevice, privacy: .public))")
    }

    /// Stops and returns the final transcript.
    @discardableResult
    func stop() -> String {
        guard state == .listening || state == .preparing else { return transcript }
        state = .finishing
        request?.endAudio()
        // Give the recognizer a moment to flush its last result rather than
        // truncating the final word.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.finishInternal()
        }
        return transcript
    }

    func cancel() {
        transcript = ""
        finishInternal()
    }

    private func finishInternal() {
        timeoutTask?.cancel()
        timeoutTask = nil
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        inputLevel = 0
        isPartial = false
        state = .idle
        deactivateAudioSession()
    }

    private var isUnavailableState: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let limit = maximumDuration
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, !Task.isCancelled, self.state == .listening else { return }
            AppLog.capture.info("Dictation hit its time limit")
            self.stop()
        }
    }

    // MARK: Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` with `.duckOthers` so a staffer's music dips instead of
        // stopping, and `.allowBluetooth` so a headset mic works.
        try session.setCategory(
            .record,
            mode: .measurement,
            options: [.duckOthers, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        // Failure here is not actionable and must not surface to the user.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// RMS of the buffer, mapped to a 0–1 scale that looks right on a meter.
    private static func meterLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameCount))
        // -50 dB floor: quiet speech should still move the meter.
        let decibels = 20 * log10(max(rms, 1e-7))
        let normalized = (Double(decibels) + 50) / 50
        return min(max(normalized, 0), 1)
    }
}
