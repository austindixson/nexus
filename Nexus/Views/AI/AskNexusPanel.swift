import SwiftUI

/// Right-sidebar panel: grounded vault Q&A with clickable citations + studio.
struct AskNexusPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var aiConfig = AIConfiguration.shared

    @State private var question = ""
    @State private var answerMarkdown = ""
    @State private var citations: [RetrievedPassage] = []
    @State private var providerLabel = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var studioKind: StudioService.ArtifactKind = .summaryNote
    @State private var studioTopic = ""
    @State private var studioBusy = false
    @State private var studioMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                askSection

                if !answerMarkdown.isEmpty || isLoading || errorText != nil {
                    answerSection
                }
                if !citations.isEmpty {
                    citationsSection
                }

                Divider()

                studioSection
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Ask Nexus", systemImage: "sparkles")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 4)
            Text(aiConfig.isEnabled ? aiConfig.providerKind.title : "Offline")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Question")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("Ask about your vault…", text: $question, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await runAsk() } }

            Picker("Scope", selection: $aiConfig.scopeMode) {
                ForEach(AIConfiguration.ScopeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    Task { await runAsk() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44)
                    } else {
                        Label("Ask", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)

                Button("Clear") {
                    answerMarkdown = ""
                    citations = []
                    errorText = nil
                    providerLabel = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading)
            }
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Answer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !providerLabel.isEmpty {
                    Text(providerLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if isLoading && answerMarkdown.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Retrieving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !answerMarkdown.isEmpty {
                Text(answerMarkdown)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var citationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Citations")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(Array(citations.enumerated()), id: \.element.id) { idx, c in
                Button {
                    app.openNote(path: c.path)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("[\(idx + 1)] \(c.title)")
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("L\(c.lineStart)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(c.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Text(c.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var studioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Studio", systemImage: "wand.and.stars")
                .font(.headline)

            Text("Generate notes from the current scope.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Artifact", selection: $studioKind) {
                ForEach(StudioService.ArtifactKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Topic (optional)", text: $studioTopic)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await runStudio() }
            } label: {
                if studioBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Generate", systemImage: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(studioBusy)

            if let studioMessage {
                Text(studioMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func runAsk() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isLoading = true
        errorText = nil
        answerMarkdown = ""
        citations = []

        let notes = app.vault.notes
        let index = app.vault.indexStore
        let selected = app.selectedPath
        let backlinks = app.linkIndex.backlinks
        let scope = aiConfig.scopeMode

        do {
            let result: AskNexusAnswer
            if aiConfig.isEnabled {
                result = try await ChatAgent.askStreaming(
                    question: q,
                    notes: notes,
                    index: index,
                    config: aiConfig,
                    selectedPath: selected,
                    backlinks: backlinks,
                    onChunk: { partial in
                        answerMarkdown = partial
                    }
                )
            } else {
                result = ChatAgent.offlineBrief(
                    question: q,
                    notes: notes,
                    index: index,
                    selectedPath: selected,
                    backlinks: backlinks,
                    scope: scope
                )
            }
            answerMarkdown = result.text
            citations = result.citations
            providerLabel = result.usedProvider
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func runStudio() async {
        studioBusy = true
        studioMessage = "Generating…"
        do {
            let path = try await StudioService.generate(
                kind: studioKind,
                topic: studioTopic,
                notes: app.vault.notes,
                index: app.vault.indexStore,
                config: aiConfig,
                selectedPath: app.selectedPath,
                backlinks: app.linkIndex.backlinks,
                vault: app.vault
            )
            studioMessage = "Created \(path)"
            if path.hasSuffix(".canvas") {
                app.openCanvas(path: path)
            } else {
                app.openNote(path: path)
            }
        } catch {
            studioMessage = error.localizedDescription
        }
        studioBusy = false
    }
}
