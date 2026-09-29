import SwiftUI
import AppKit

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
    @State private var lastAskWasOffline = false
    @State private var studioKind: StudioService.ArtifactKind = .summaryNote
    @State private var studioTopic = ""
    @State private var studioBusy = false
    @State private var studioMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                askSection

                if lastAskWasOffline && !aiConfig.isEnabled && (!citations.isEmpty || !answerMarkdown.isEmpty) {
                    offlineEnableBanner
                }

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
                .foregroundStyle(aiConfig.isEnabled ? .secondary : Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (aiConfig.isEnabled ? Color.primary.opacity(0.06) : Color.orange.opacity(0.15)),
                    in: Capsule()
                )
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
                    lastAskWasOffline = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading)
            }
        }
    }

    /// Shown after an offline ask so the user can turn AI on without hunting Settings.
    private var offlineEnableBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI is offline", systemImage: "wifi.slash")
                .font(.subheadline.weight(.semibold))
            Text("These are ranked vault hits only. Enable a provider to synthesize an answer with citations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    aiConfig.providerKind = .ollama
                    if aiConfig.modelID.isEmpty { aiConfig.modelID = "llama3.2" }
                    lastAskWasOffline = false
                    Task { await runAsk() }
                } label: {
                    Label("Use Ollama", systemImage: "laptopcomputer")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isLoading)
                .help("Local models — no API key required if Ollama is running.")

                Button {
                    openAISettings()
                } label: {
                    Label("AI Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lastAskWasOffline ? "Matches" : "Answer")
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
            // Offline: the structured citation cards are the results — keep
            // answerMarkdown as a short status line only.
            if !answerMarkdown.isEmpty, !lastAskWasOffline || citations.isEmpty {
                markdownBody(answerMarkdown)
            } else if lastAskWasOffline, !citations.isEmpty {
                Text(answerMarkdown.isEmpty
                     ? "\(citations.count) vault hit\(citations.count == 1 ? "" : "s") for your question."
                     : answerMarkdown)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var citationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lastAskWasOffline ? "Results" : "Citations")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(Array(citations.enumerated()), id: \.element.id) { idx, c in
                Button {
                    app.openNote(path: c.path)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(rankColor(idx), in: Circle())

                        VStack(alignment: .leading, spacing: 5) {
                            Text(c.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Text(cleanedSnippet(c.snippet))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                Text(c.path)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("L\(c.lineStart)")
                                    .font(.caption2.monospacedDigit())
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
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

    // MARK: - Formatting helpers

    @ViewBuilder
    private func markdownBody(_ raw: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(raw)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Strip YAML fence noise so snippets read as prose, not frontmatter dumps.
    private func cleanedSnippet(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("---") {
            if let end = s.range(of: "\n---") {
                s = String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.isEmpty ? raw : s
    }

    private func rankColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color.accentColor
        case 1: return Color.accentColor.opacity(0.75)
        case 2: return Color.accentColor.opacity(0.55)
        default: return Color.secondary.opacity(0.55)
        }
    }

    private func openAISettings() {
        // Bring the Settings window forward; user lands on tabs including AI.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
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
        lastAskWasOffline = !aiConfig.isEnabled

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
