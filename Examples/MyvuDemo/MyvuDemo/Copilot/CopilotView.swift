import SwiftUI

struct CopilotView: View {
    @EnvironmentObject private var glasses: GlassesModel
    @ObservedObject var model: CopilotModel

    var body: some View {
        Form {
            Section {
                StatusBadge(state: glasses.state)
                Label(model.status, systemImage: model.isCapturing ? "waveform" : "mic")
                    .accessibilityIdentifier("copilot.status")
                Text("Glasses microphone · No voice replies · 10-minute test")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("On-device English transcription", isOn: $model.transcribeLocally)
                    .disabled(model.isBusy)
                Toggle("Save a local WAV recording", isOn: $model.saveRecording)
                    .disabled(model.isBusy)
                if model.phase == .idle {
                    Button("Start microphone test") { glasses.startCopilot() }
                        .disabled(!glasses.isReady || model.isPreparingModel)
                        .accessibilityIdentifier("copilot.start")
                } else {
                    Button(model.phase == .stopping ? "Stopping…" : "Stop", role: .destructive) { model.stop() }
                        .disabled(model.phase == .stopping)
                        .accessibilityIdentifier("copilot.stop")
                }
            } header: { Text("Capture") } footer: {
                Text("After starting, trigger the voice assistant on your glasses and speak. "
                    + "Audio is processed on this iPhone. A WAV is saved only when enabled. "
                    + "Continuous capture and lock-screen operation are still being tested.")
            }

            Section("Apple transcription") {
                Text(model.speechStatus).font(.footnote)
                if model.isPreparingModel {
                    ProgressView()
                    Button("Cancel model preparation") { model.cancelModelPreparation() }
                } else {
                    Button("Prepare English model") { model.prepareModel() }.disabled(model.isBusy)
                }
                if !model.transcript.isEmpty { Text(model.transcript).textSelection(.enabled) }
                if !model.partial.isEmpty { Text(model.partial).foregroundStyle(.secondary) }
                if model.transcript.isEmpty, model.partial.isEmpty {
                    Text("Recognized speech will appear here.").foregroundStyle(.secondary)
                }
            }

            Section("Microphone diagnostics") {
                if let update = model.update {
                    LabeledContent("Session elapsed", value: duration(update.wallDuration))
                    LabeledContent("Decoded audio", value: duration(update.stats.audioDuration))
                    LabeledContent("Opus frames", value: "\(update.stats.frames)")
                    LabeledContent("Audio messages", value: "\(update.stats.messages)")
                    LabeledContent("Level", value: String(format: "%.0f dBFS", update.stats.levelDB))
                    ProgressView(value: max(0, min(1, (update.stats.levelDB + 90) / 90)))
                    LabeledContent("Last audio message", value: update.secondsSinceAudio.map { String(format: "%.1fs ago", $0) } ?? "Not received")
                    LabeledContent("Malformed messages", value: "\(update.stats.malformedMessages)")
                    LabeledContent("Decoder errors", value: "\(update.stats.decodeErrors)")
                    LabeledContent("Assistant triggers", value: "\(update.triggerCount)")
                } else { Text("Start a test to inspect the audio stream.").foregroundStyle(.secondary) }
            }

            Section {
                Button("Show a test hint for 10 seconds") { model.showTestCard() }
                    .disabled(!model.isCapturing)
                if !model.cardStatus.isEmpty { Text(model.cardStatus).font(.caption) }
            } header: { Text("Display while listening") } footer: {
                Text("This sends a fixed test question. Automatic conversation advice is not enabled yet.")
            }

            if model.recordingURL != nil || model.reportURL != nil {
                Section("Test files") {
                    if let url = model.recordingURL { ShareLink("Export WAV recording", item: url) }
                    if let url = model.reportURL { ShareLink("Export diagnostic report", item: url) }
                    Text("Saved under Files → On My iPhone → MyvuDemos → CopilotDiagnostics. "
                        + "WAV time is decoded audio time; gaps are not filled with synthetic silence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Copilot")
    }

    private func duration(_ value: Double) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
