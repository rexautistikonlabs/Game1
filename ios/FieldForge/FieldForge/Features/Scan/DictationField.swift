//
//  DictationField.swift
//  FieldForge
//
//  A text field with a microphone that works with no signal.
//
//  This is the "voice notes while walking" feature. On-device transcription
//  means it works in a basement, in a rural county, and without sending a
//  donor conversation to a server. The live transcript appears as the staffer
//  talks so they can see it is working, and the text stays fully editable
//  afterwards — dictation fills the field, it does not own it.
//

import SwiftUI

struct DictationField: View {

    @Binding var text: String
    @Binding var wasDictated: Bool
    var placeholder: String = ""

    @Environment(\.appEnvironment) private var app

    /// What the field held before dictation started, so the transcript is
    /// appended rather than replacing something already typed.
    @State private var textBeforeDictation = ""
    @State private var unavailableMessage: String?

    private var transcriber: SpeechTranscriber { app.transcriber }

    private var isListening: Bool {
        transcriber.state == .listening || transcriber.state == .preparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ZStack(alignment: .topLeading) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(Type.body)
                    .lineLimit(3...8)
                    .padding(Space.sm)
                    .padding(.trailing, 48)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                            .strokeBorder(
                                isListening ? Palette.brand : Palette.separator,
                                lineWidth: isListening ? 2 : 0.5
                            )
                    )

                HStack {
                    Spacer()
                    micButton
                        .padding(Space.sm)
                }
            }

            if isListening {
                listeningIndicator
            } else if let unavailableMessage {
                Text(unavailableMessage)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else if wasDictated, text.trimmedOrNil != nil {
                Label("Dictated — worth a glance", systemImage: "waveform")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        // The live transcript flows straight into the field.
        .onChange(of: transcriber.transcript) { _, transcript in
            guard isListening, !transcript.isEmpty else { return }
            let prefix = textBeforeDictation.trimmedOrNil.map { $0 + " " } ?? ""
            text = prefix + transcript
            wasDictated = true
        }
    }

    private var micButton: some View {
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: isListening ? "stop.circle.fill" : "mic.fill")
                .font(.title3)
                .foregroundStyle(isListening ? Palette.critical : Palette.brand)
                .frame(width: 36, height: 36)
                .background(
                    (isListening ? Palette.critical : Palette.brand).opacity(0.12),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Stop dictating" : "Dictate a note")
        .accessibilityHint(isListening ? "" : "Transcription happens on this iPhone and works offline")
    }

    /// A live level meter plus a plain statement of where the audio is going.
    /// People are rightly suspicious of microphones; saying "on this iPhone"
    /// out loud is the least the app can do.
    private var listeningIndicator: some View {
        HStack(spacing: Space.sm) {
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(barIsLit(index) ? Palette.brand : Palette.separator)
                        .frame(width: 3, height: barHeight(index))
                }
            }
            .accessibilityHidden(true)

            Text(transcriber.isOnDevice ? "Listening — staying on this iPhone" : "Listening")
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .animation(.linear(duration: 0.08), value: transcriber.inputLevel)
    }

    private func barIsLit(_ index: Int) -> Bool {
        Double(index) / 12 < transcriber.inputLevel
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // A gentle arc, tallest in the middle, so it reads as a meter rather
        // than a progress bar.
        let distanceFromCentre = abs(Double(index) - 5.5) / 5.5
        return 8 + (1 - distanceFromCentre) * 10
    }

    private func toggle() async {
        if isListening {
            let final = transcriber.stop()
            if !final.isEmpty {
                let prefix = textBeforeDictation.trimmedOrNil.map { $0 + " " } ?? ""
                text = prefix + final
                wasDictated = true
            }
            Haptics.step()
            return
        }

        guard transcriber.isAvailable else {
            unavailableMessage = "Dictation is not available on this iPhone right now. You can still type."
            return
        }
        unavailableMessage = nil
        textBeforeDictation = text
        Haptics.step()
        await transcriber.start()

        if case .unavailable(let reason) = transcriber.state {
            unavailableMessage = reason
        }
    }
}
