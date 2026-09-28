import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportSheetView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var webURL = ""
    @State private var pasteTitle = ""
    @State private var pasteBody = ""
    @State private var status: String?
    @State private var busy = false
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import source")
                .font(.title2.weight(.semibold))
            Text("Imports become Markdown notes under Sources/ — first-class vault content.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("", selection: $tab) {
                Text("File").tag(0)
                Text("Web / YouTube").tag(1)
                Text("Paste text").tag(2)
            }
            .pickerStyle(.segmented)

            Group {
                switch tab {
                case 0:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PDF, Markdown, or plain text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Choose File…") { pickFile() }
                            .buttonStyle(.borderedProminent)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://… or YouTube URL", text: $webURL)
                            .textFieldStyle(.roundedBorder)
                        Text("YouTube links import title + captions when available.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button("Import URL") {
                            Task { await importWeb() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                default:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $pasteTitle)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $pasteBody)
                            .font(.body)
                            .frame(minHeight: 160)
                            .border(Color.secondary.opacity(0.2))
                        Button("Import text") {
                            importPaste()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pasteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                }
            }

            if busy {
                ProgressView("Importing…")
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, .text, UTType(filenameExtension: "md")].compactMap { $0 }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await importFile(url)
            }
        }
    }

    @MainActor
    private func importFile(_ url: URL) async {
        busy = true
        status = nil
        do {
            let result: SourceImporter.Result
            if url.pathExtension.lowercased() == "pdf" {
                result = try SourceImporter.importPDF(url: url, into: app.vault)
            } else {
                result = try SourceImporter.importTextFile(url: url, into: app.vault)
            }
            status = "Imported \(result.path)"
            app.openNote(path: result.path)
        } catch {
            status = error.localizedDescription
        }
        busy = false
    }

    @MainActor
    private func importWeb() async {
        busy = true
        status = nil
        do {
            let result = try await SourceImporter.importWebURL(webURL, into: app.vault)
            status = "Imported \(result.path)"
            app.openNote(path: result.path)
        } catch {
            status = error.localizedDescription
        }
        busy = false
    }

    @MainActor
    private func importPaste() {
        busy = true
        status = nil
        do {
            let result = try SourceImporter.importPastedText(title: pasteTitle, text: pasteBody, into: app.vault)
            status = "Imported \(result.path)"
            app.openNote(path: result.path)
        } catch {
            status = error.localizedDescription
        }
        busy = false
    }
}
