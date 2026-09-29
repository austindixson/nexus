import Foundation

struct AIMessage: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String
}

struct AIChatRequest: Sendable {
    var messages: [AIMessage]
    var model: String?
    var temperature: Double
    var maxTokens: Int?

    init(messages: [AIMessage], model: String? = nil, temperature: Double = 0.3, maxTokens: Int? = 2048) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

protocol AIProvider: Sendable {
    var displayName: String { get }
    func complete(_ request: AIChatRequest) async throws -> String
    /// Token/chunk stream when supported; default falls back to single complete().
    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<String, Error>
}

extension AIProvider {
    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let text = try await complete(request)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum AIError: LocalizedError {
    case disabled
    case missingAPIKey
    case badURL
    case unreachable(String)
    case httpStatus(Int, String)
    case emptyResponse
    case decoding

    var errorDescription: String? {
        switch self {
        case .disabled: return "AI is disabled. Enable a provider in Settings."
        case .missingAPIKey: return "Missing API key. Add one in Settings → AI (stored in Keychain)."
        case .badURL: return "Invalid API base URL. Use http(s)://host[:port]/path]."
        case .unreachable(let detail): return "Could not reach model endpoint: \(detail)"
        case .httpStatus(let code, let body): return "API error \(code): \(body.prefix(240))"
        case .emptyResponse: return "Empty response from model."
        case .decoding: return "Could not decode model response."
        }
    }
}

// MARK: - OpenAI-compatible (xAI / OpenAI / proxies)

struct OpenAICompatibleProvider: AIProvider {
    let name: String
    let baseURL: URL
    let apiKey: String
    let defaultModel: String

    var displayName: String { name }

    func complete(_ request: AIChatRequest) async throws -> String {
        var collected = ""
        for try await chunk in stream(request) {
            collected += chunk
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }

    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("chat/completions")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 120

                    let payload: [String: Any] = [
                        "model": request.model ?? defaultModel,
                        "temperature": request.temperature,
                        "stream": true,
                        "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "max_tokens": request.maxTokens ?? 2048,
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.emptyResponse
                    }
                    if http.statusCode >= 400 {
                        var errBody = ""
                        for try await line in bytes.lines {
                            errBody += line
                            if errBody.count > 500 { break }
                        }
                        throw AIError.httpStatus(http.statusCode, errBody)
                    }

                    var yielded = false
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let first = choices.first
                        else { continue }

                        // OpenAI stream: delta.content
                        if let delta = first["delta"] as? [String: Any],
                           let content = delta["content"] as? String,
                           !content.isEmpty {
                            yielded = true
                            continuation.yield(content)
                        } else if let message = first["message"] as? [String: Any],
                                  let content = message["content"] as? String,
                                  !content.isEmpty {
                            yielded = true
                            continuation.yield(content)
                        }
                    }
                    if !yielded {
                        // Some gateways ignore stream=true — fall back
                        let text = try await completeNonStream(request)
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.unreachable(error.localizedDescription))
                }
            }
        }
    }

    private func completeNonStream(_ request: AIChatRequest) async throws -> String {
        let url = baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let payload: [String: Any] = [
            "model": request.model ?? defaultModel,
            "temperature": request.temperature,
            "stream": false,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": request.maxTokens ?? 2048,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.emptyResponse }
        if http.statusCode >= 400 {
            throw AIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw AIError.decoding }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }
}

// MARK: - Anthropic Messages API

struct AnthropicProvider: AIProvider {
    let baseURL: URL
    let apiKey: String
    let defaultModel: String

    var displayName: String { "Anthropic" }

    func complete(_ request: AIChatRequest) async throws -> String {
        var collected = ""
        for try await chunk in stream(request) {
            collected += chunk
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }

    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let text = try await completeStream(request, continuation: continuation)
                    if !text {
                        let fallback = try await completeNonStream(request)
                        continuation.yield(fallback)
                    }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.unreachable(error.localizedDescription))
                }
            }
        }
    }

    /// Returns true if any streamed text was yielded.
    private func completeStream(
        _ request: AIChatRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> Bool {
        let url = baseURL.appendingPathComponent("v1/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 120

        let (system, messages) = Self.splitSystem(request.messages)
        var payload: [String: Any] = [
            "model": request.model ?? defaultModel,
            "max_tokens": request.maxTokens ?? 2048,
            "temperature": request.temperature,
            "stream": true,
            "messages": messages,
        ]
        if let system, !system.isEmpty {
            payload["system"] = system
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.emptyResponse }
        if http.statusCode >= 400 {
            var errBody = ""
            for try await line in bytes.lines {
                errBody += line
                if errBody.count > 500 { break }
            }
            throw AIError.httpStatus(http.statusCode, errBody)
        }

        var yielded = false
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String,
               !text.isEmpty {
                yielded = true
                continuation.yield(text)
            }
            if type == "message_stop" { break }
        }
        return yielded
    }

    private func completeNonStream(_ request: AIChatRequest) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 120

        let (system, messages) = Self.splitSystem(request.messages)
        var payload: [String: Any] = [
            "model": request.model ?? defaultModel,
            "max_tokens": request.maxTokens ?? 2048,
            "temperature": request.temperature,
            "stream": false,
            "messages": messages,
        ]
        if let system, !system.isEmpty {
            payload["system"] = system
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.emptyResponse }
        if http.statusCode >= 400 {
            throw AIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else { throw AIError.decoding }
        let text = content
            .compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            .joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }

    private static func splitSystem(_ messages: [AIMessage]) -> (String?, [[String: String]]) {
        var systemParts: [String] = []
        var rest: [[String: String]] = []
        for m in messages {
            switch m.role {
            case .system:
                systemParts.append(m.content)
            case .user:
                rest.append(["role": "user", "content": m.content])
            case .assistant:
                rest.append(["role": "assistant", "content": m.content])
            }
        }
        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        return (system, rest)
    }
}

// MARK: - Ollama (local or Tailscale / remote URL)

struct OllamaProvider: AIProvider {
    let baseURL: URL
    let defaultModel: String

    var displayName: String { "Ollama" }

    func complete(_ request: AIChatRequest) async throws -> String {
        var collected = ""
        for try await chunk in stream(request) {
            collected += chunk
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }

    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("api/chat")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 180
                    let payload: [String: Any] = [
                        "model": request.model ?? defaultModel,
                        "stream": true,
                        "options": ["temperature": request.temperature],
                        "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var err = ""
                        for try await line in bytes.lines {
                            err += line
                            if err.count > 400 { break }
                        }
                        throw AIError.httpStatus(http.statusCode, err)
                    }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let message = json["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.unreachable(error.localizedDescription))
                }
            }
        }
    }
}
