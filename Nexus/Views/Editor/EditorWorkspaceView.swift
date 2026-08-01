import SwiftUI
import AppKit
import WebKit

struct EditorWorkspaceView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if let path = app.selectedPath, app.vault.notes[path] != nil || path.hasSuffix(".md") {
                editorBody(path: path)
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private func editorBody(path: String) -> some View {
        switch app.editorMode {
        case .source:
            MarkdownSourceEditor(text: Binding(
                get: { app.draftContent },
                set: { app.updateDraft($0) }
            ), onCommandClick: openWikiTarget)
        case .livePreview:
            MarkdownPreview(content: app.draftContent, title: app.currentNote?.title ?? "")
                .onOpenWikiLink(openWikiTarget)
        case .split:
            HSplitView {
                MarkdownSourceEditor(text: Binding(
                    get: { app.draftContent },
                    set: { app.updateDraft($0) }
                ), onCommandClick: openWikiTarget)
                .frame(minWidth: 280)

                MarkdownPreview(content: app.draftContent, title: app.currentNote?.title ?? "")
                    .onOpenWikiLink(openWikiTarget)
                    .frame(minWidth: 280)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No note selected")
                .font(.title2)
            Text("Open a note from the file explorer, or create one with ⌘N.")
                .foregroundStyle(.secondary)
            HStack {
                Button("New Note") { app.createNote() }
                    .buttonStyle(.borderedProminent)
                Button("Open Graph") { app.mainMode = .graph }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openWikiTarget(_ target: String) {
        let known = app.vault.knownPaths
        if let resolved = MarkdownParser.resolveLinkTarget(target, from: app.selectedPath ?? "", knownPaths: known) {
            app.openNote(path: resolved)
        } else if let path = app.vault.createNote(named: target) {
            app.openNote(path: path)
        }
    }
}

// MARK: - Tab strip

struct TabStripView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(app.openTabs, id: \.self) { path in
                    tab(path)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 34)
        .background(.bar)
    }

    private func tab(_ path: String) -> some View {
        let selected = path == app.selectedPath
        let title = app.vault.notes[path]?.title ?? (path as NSString).deletingPathExtension
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Button {
                app.closeTab(path)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(0.55)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.primary.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) {
            if selected {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.openNote(path: path) }
        .contextMenu {
            Button("Close") { app.closeTab(path) }
            Button("Close Others") {
                for t in app.openTabs where t != path { app.closeTab(t) }
            }
            Button("Reveal in Finder") {
                if let url = app.vault.absoluteURL(for: path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}

// MARK: - Source editor (AppKit NSTextView for performance + native feel)

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommandClick: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // Avoid clip-view content insets stealing the first line of text.
        scroll.contentInsets = .init()
        scroll.scrollerInsets = .init()

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Soft-wrap to the visible width so long lines are never clipped horizontally.
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.containerSize = NSSize(
            width: max(scroll.contentSize.width, 1),
            height: CGFloat.greatestFiniteMagnitude
        )
        // Generous inset so the first/last lines never sit under the clip edge.
        textView.textContainerInset = NSSize(width: 28, height: 28)

        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.observeBounds(of: scroll)
        Self.applyHighlight(textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.syncContainerWidth(scroll: nsView, textView: textView)
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
            Self.applyHighlight(textView)
            // Keep the top of the document visible when swapping notes so the first line isn't clipped.
            if selected.first?.rangeValue.location == 0 {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?

        init(_ parent: MarkdownSourceEditor) {
            self.parent = parent
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func observeBounds(of scroll: NSScrollView) {
            scrollView = scroll
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            // When the split pane resizes, force the text container to match so lines re-wrap
            // instead of being clipped past the right edge.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, let scroll = self.scrollView, let tv = self.textView else { return }
                self.syncContainerWidth(scroll: scroll, textView: tv)
            }
            scroll.contentView.postsFrameChangedNotifications = true
        }

        func syncContainerWidth(scroll: NSScrollView, textView: NSTextView) {
            let width = max(scroll.contentSize.width, 1)
            guard let container = textView.textContainer else { return }
            if abs(container.containerSize.width - width) > 0.5 {
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                textView.layoutManager?.ensureLayout(for: container)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            MarkdownSourceEditor.applyHighlight(tv)
        }
    }

    fileprivate static func applyHighlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ], range: full)

        let text = storage.string as NSString
        let patterns: [(String, NSColor)] = [
            (#"\[\[.*?\]\]"#, NSColor.systemBlue),
            (#"(?<![\w/])#[\w\-/]+"#, NSColor.systemPurple),
            (#"^#{1,6}\s.*$"#, NSColor.systemOrange),
            (#"`[^`]+`"#, NSColor.systemTeal),
            (#"^\s*[-*]\s\[.\]\s.*$"#, NSColor.secondaryLabelColor),
            (#"^---$"#, NSColor.tertiaryLabelColor),
        ]

        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            regex.enumerateMatches(in: text as String, options: [], range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttributes([.foregroundColor: color], range: match.range)
            }
        }
        storage.endEditing()
    }
}

// MARK: - Preview

private struct WikiOpenKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openWikiLink: ((String) -> Void)? {
        get { self[WikiOpenKey.self] }
        set { self[WikiOpenKey.self] = newValue }
    }
}

extension View {
    func onOpenWikiLink(_ action: @escaping (String) -> Void) -> some View {
        environment(\.openWikiLink, action)
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let content: String
    let title: String
    @Environment(\.openWikiLink) private var openWikiLink

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "nexus")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.open = { [openWikiLink] target in
            openWikiLink?(target)
        }
        let html = MarkdownParser.renderPreviewHTML(content, title: title)
        web.loadHTMLString(html, baseURL: Self.katexBaseURL)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.open = { [openWikiLink] target in
            openWikiLink?(target)
        }
        let html = MarkdownParser.renderPreviewHTML(content, title: title)
        web.loadHTMLString(html, baseURL: Self.katexBaseURL)
    }

    /// Base URL for offline KaTeX assets (Xcode flattens Resources/katex/* into Resources/).
    private static var katexBaseURL: URL? {
        if let url = Bundle.main.url(forResource: "katex.min", withExtension: "js") {
            return url.deletingLastPathComponent()
        }
        if let url = Bundle.main.url(forResource: "katex.min", withExtension: "js", subdirectory: "katex") {
            return url.deletingLastPathComponent()
        }
        return Bundle.main.resourceURL
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var open: ((String) -> Void)?

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else { return }
            // nexus://note/Target
            let target = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .removingPercentEncoding ?? url.lastPathComponent
            DispatchQueue.main.async {
                self.open?(target.isEmpty ? (url.host ?? "") : target)
            }
            let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.scheme == "nexus" {
                let target = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                open?(target.isEmpty ? (url.host ?? "") : target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
