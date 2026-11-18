import MyvuAudio
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
                Text(model.channel == .transcribe
                     ? "Glasses Transcribe app · No voice replies · 30-minute test"
                     : "Glasses assistant microphone · No voice replies · 10-minute test")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Audio source", selection: $model.channel) {
                    ForEach(CopilotModel.Channel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("copilot.channel")
                if model.channel == .transcribe {
                    Toggle("Open Transcribe on the glasses from this iPhone", isOn: $model.openTranscribeFromPhone)
                        .disabled(model.isBusy)
                }
                Toggle("On-device English transcription", isOn: $model.transcribeLocally)
                    .disabled(model.isBusy)
                Toggle("Save a local WAV recording", isOn: $model.saveRecording)
                    .disabled(model.isBusy)
                if model.phase == .idle {
                    Button("Start listening") { glasses.startCopilot() }
                        .disabled(!glasses.isReady || model.isPreparingModel)
                        .accessibilityIdentifier("copilot.start")
                } else {
                    if model.isCapturing, model.activeChannel == .assistant {
                        Button("Request glasses microphone again") { model.requestMicrophone() }
                            .accessibilityIdentifier("copilot.requestMicrophone")
                    }
                    if model.isCapturing, model.activeChannel == .transcribe {
                        Button("Ask the glasses to open Transcribe again") { model.openTranscribeOnGlasses() }
                            .accessibilityIdentifier("copilot.openTranscribe")
                        Button("Announce the phone service again") { model.sendTranscribeStart() }
                            .accessibilityIdentifier("copilot.sendTranscribeStart")
                    }
                    Button(model.phase == .stopping ? "Stopping…" : "Stop", role: .destructive) { model.stop() }
                        .disabled(model.phase == .stopping)
                        .accessibilityIdentifier("copilot.stop")
                }
            } header: { Text("Capture") } footer: {
                if model.channel == .transcribe {
                    Text("Start uses the glasses' own Transcribe feature, which is meant for long recordings. "
                        + "If the glasses do not open it, open Transcribe from the glasses menu yourself; "
                        + "this iPhone answers the glasses and starts the session. Silence does not end the session. "
                        + "This channel is still experimental: the start handshake and audio format are being verified. "
                        + "With WAV saving on, the raw Transcribe audio packets are also kept for analysis.")
                } else {
                    Text("Start requests the glasses microphone from this iPhone. "
                        + "If no audio arrives, hold the physical power button underneath the right temple "
                        + "for about 1 second, then release and speak. There is no separate assistant menu to find. "
                        + "Audio is processed on this iPhone. A WAV is saved only when enabled. "
                        + "This channel stops after about 30 seconds in tests so far.")
                }
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

            if model.activeChannel == .transcribe, let update = model.transcribeUpdate {
                TranscribeDiagnosticsSection(update: update)
            }

            Section("Microphone diagnostics") {
                if model.activeChannel == .transcribe {
                    Text("See Transcribe channel above.").foregroundStyle(.secondary)
                } else if let update = model.update {
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
                    LabeledContent("Microphone requests", value: "\(update.launchRequests)")
                    LabeledContent("Continuous Conversation at start",
                                   value: update.continuousDialogueEnabled ? "On" : "Off")
                    LabeledContent("Longest audio gap", value: update.longestAudioGap.map {
                        String(format: "%.1fs", $0)
                    } ?? "No audio yet")
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

private struct TranscribeDiagnosticsSection: View {
    let update: TranscribeChannelCapture.Update

    var body: some View {
        Section("Transcribe channel") {
            LabeledContent("Session elapsed", value: clock(update.wallDuration))
            LabeledContent("Glasses Transcribe ready", value: update.glassesReady ? "Yes" : "Not yet")
            LabeledContent("Open requests / start requests", value: "\(update.sceneRequests) / \(update.startRequests)")
            LabeledContent("Transcribing", value: update.transcribedStream?.rawValue.capitalized ?? "No stream yet")
            stream("Wearer (proximal)", update.proximal)
            stream("Other side (remote)", update.remote)
            LabeledContent("Last audio", value: update.secondsSinceAudio.map { String(format: "%.1fs ago", $0) } ?? "Not received")
            LabeledContent("Longest audio gap", value: update.longestAudioGap.map { String(format: "%.1fs", $0) } ?? "No audio yet")
            LabeledContent("Speech segments", value: "\(update.speechSegments)")
            if !update.observedPackages.isEmpty {
                LabeledContent("Glasses packages", value: update.observedPackages.joined(separator: "\n"))
                    .font(.caption)
            }
            DisclosureGroup("Inbound traffic (\(update.inbound.count) kinds)") {
                ForEach(Array(update.inbound.enumerated()), id: \.offset) { _, bucket in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bucket.key).font(.caption2.monospaced())
                        Text("\(bucket.count)× · \(bucket.bytes) B · \(bucket.minSize)–\(bucket.maxSize) B · "
                             + String(format: "%.1f–%.1fs", bucket.firstAt, bucket.lastAt))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Recent protocol events (\(update.events.count + update.omittedEvents))") {
                ForEach(Array(update.events.suffix(20).enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%6.1fs  %@  %@", event.elapsed, arrow(event.direction), event.name))
                            .font(.caption.monospaced())
                        if let detail = event.detail {
                            Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func stream(_ title: String, _ stats: TranscribeStreamStats) -> some View {
        LabeledContent(title, value: stats.messages == 0 ? "No packets"
            : "\(stats.format.rawValue) · \(stats.messages) msgs · \(clock(stats.audioDuration)) audio · "
                + String(format: "%.0f dBFS", stats.levelDB))
    }

    private func arrow(_ direction: TranscribeChannelCapture.Event.Direction) -> String {
        switch direction {
        case .sent: return "→"
        case .received: return "←"
        case .note: return "•"
        }
    }

    private func clock(_ value: Double) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
