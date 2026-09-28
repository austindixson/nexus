import Foundation

struct AskNexusAnswer: Sendable {
    var text: String
    var citations: [RetrievedPassage]
    var usedProvider: String
}

/// Grounded Q&A over the vault: retrieve passages, force citation discipline, call AI provider.
enum ChatAgent {
    /// Streaming ask — yields partial answer text; final call returns full answer + citations.
    static func askStreaming(
        question: String,
        notes: [String: NoteDocument],
        index: VaultIndexStore?,
        config: AIConfiguration,
        selectedPath: String?,
        backlinks: [String: [Backlink]],
        onChunk: @MainActor @escaping (String) -> Void
    ) async throws -> AskNexusAnswer {
        guard let provider = await MainActor.run(body: { config.makeProvider() }) else {
            throw AIError.disabled
        }

        let scope = await MainActor.run { config.scopeMode }
        let allowGeneral = await MainActor.run { config.allowGeneralKnowledge }

        let allowed = RetrievalService.resolveAllowedPaths(
            scope: scope,
            selectedPath: selectedPath,
            notes: notes,
            backlinks: backlinks
        )

        let passages = RetrievalService.search(
            question: question,
            notes: notes,
            index: index,
            allowedPaths: allowed
        )
        let (context, used) = RetrievalService.buildContextBlock(passages: passages)

        let system: String
        if allowGeneral {
            system = """
            You are Nexus, a local knowledge-base assistant on macOS.
            Prefer the vault passages below. Cite them as [n] matching <passage index="n">.
            You may add brief general knowledge only when the vault is insufficient, and label it clearly.
            Be concise and accurate. Use Markdown.
            """
        } else {
            system = """
            You are Nexus, a local knowledge-base assistant on macOS.
            Answer ONLY using the vault passages provided.
            Cite sources inline as [n] matching <passage index="n">.
            If the passages are insufficient, say what is missing and suggest which notes to open — do not invent facts.
            Be concise. Use Markdown.
            """
        }

        let user = """
        Question: \(question)

        Vault passages:
        \(context.isEmpty ? "(no matching passages)" : context)
        """

        let request = AIChatRequest(
            messages: [
                AIMessage(role: .system, content: system),
                AIMessage(role: .user, content: user),
            ],
            temperature: 0.25,
            maxTokens: 2048
        )

        var full = ""
        for try await chunk in provider.stream(request) {
            full += chunk
            let snapshot = full
            await onChunk(snapshot)
        }

        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }

        return AskNexusAnswer(
            text: trimmed,
            citations: used,
            usedProvider: provider.displayName
        )
    }

    static func ask(
        question: String,
        notes: [String: NoteDocument],
        index: VaultIndexStore?,
        config: AIConfiguration,
        selectedPath: String?,
        backlinks: [String: [Backlink]]
    ) async throws -> AskNexusAnswer {
        try await askStreaming(
            question: question,
            notes: notes,
            index: index,
            config: config,
            selectedPath: selectedPath,
            backlinks: backlinks,
            onChunk: { _ in }
        )
    }

    /// Offline-only answer when AI is disabled: return ranked passages as a structured brief.
    static func offlineBrief(
        question: String,
        notes: [String: NoteDocument],
        index: VaultIndexStore?,
        selectedPath: String?,
        backlinks: [String: [Backlink]],
        scope: AIConfiguration.ScopeMode
    ) -> AskNexusAnswer {
        let allowed = RetrievalService.resolveAllowedPaths(
            scope: scope,
            selectedPath: selectedPath,
            notes: notes,
            backlinks: backlinks
        )
        let passages = RetrievalService.search(
            question: question,
            notes: notes,
            index: index,
            allowedPaths: allowed
        )
        let used = Array(passages.prefix(8))
        if used.isEmpty {
            return AskNexusAnswer(
                text: "No matching notes found for “\(question)”. Try different keywords, or enable AI in Settings for generative answers.",
                citations: [],
                usedProvider: "Offline FTS"
            )
        }
        var md = "**Search results** for “\(question)” (offline — enable AI for synthesized answers):\n\n"
        for (i, p) in used.enumerated() {
            md += "### [\(i + 1)] [[\(p.title)]] (`\(p.path)`)\n"
            md += "> \(p.snippet)\n\n"
        }
        return AskNexusAnswer(text: md, citations: used, usedProvider: "Offline FTS")
    }
}
