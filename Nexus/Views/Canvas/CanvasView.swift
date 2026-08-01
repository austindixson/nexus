import SwiftUI
import AppKit

/// Infinite freeform canvas with cards, groups, and arrows (Obsidian Canvas basic parity).
struct CanvasView: View {
    @EnvironmentObject private var app: AppState
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragCardID: String?
    @State private var dragStart: CGSize = .zero
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            canvasToolbar
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    CanvasBackground()
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if dragCardID == nil {
                                        offset = CGSize(
                                            width: offset.width + value.translation.width - dragStart.width,
                                            height: offset.height + value.translation.height - dragStart.height
                                        )
                                        dragStart = value.translation
                                    }
                                }
                                .onEnded { _ in dragStart = .zero }
                        )

                    ZStack {
                        ForEach(app.canvasDocument.groups) { group in
                            groupView(group)
                        }

                        ForEach(app.canvasDocument.edges) { edge in
                            arrowView(edge)
                        }

                        ForEach(Array(app.canvasDocument.nodes.enumerated()), id: \.element.id) { index, card in
                            cardView(index: index, card: card)
                        }
                    }
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .clipped()
                .background(Color(nsColor: .windowBackgroundColor))
                .onTapGesture { selection = nil }
                .gesture(
                    MagnificationGesture().onChanged { value in
                        scale = min(max(value, 0.25), 3)
                    }
                )
            }
        }
        .onAppear {
            if app.activeCanvasPath == nil, app.canvasDocument.nodes.isEmpty {
                app.canvasDocument.nodes = [
                    CanvasCard(
                        id: UUID().uuidString,
                        x: 80, y: 80,
                        width: 260, height: 140,
                        type: "text",
                        text: "Double-click or use + Card",
                        file: nil,
                        color: nil
                    )
                ]
            }
        }
        .onChange(of: app.canvasDocument) { _, _ in
            app.saveCanvas()
        }
    }

    private var canvasToolbar: some View {
        HStack {
            Text(app.activeCanvasPath ?? "Untitled Canvas")
                .font(.headline)
            Spacer()
            Button(action: addCard) {
                Label("Card", systemImage: "plus.rectangle")
            }
            Button(action: addGroup) {
                Label("Group", systemImage: "rectangle.dashed")
            }
            Button(action: connectSelection) {
                Label("Arrow", systemImage: "arrow.right")
            }
            .disabled(selection == nil)
            Button {
                app.newCanvas()
            } label: {
                Label("New Canvas", systemImage: "square.and.pencil")
            }
            Text("\(Int(scale * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func cardView(index: Int, card: CanvasCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.type == "file", let file = card.file {
                Text(file)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            TextField(
                "Text",
                text: Binding(
                    get: {
                        guard app.canvasDocument.nodes.indices.contains(index) else { return "" }
                        return app.canvasDocument.nodes[index].text ?? ""
                    },
                    set: { newValue in
                        guard app.canvasDocument.nodes.indices.contains(index) else { return }
                        app.canvasDocument.nodes[index].text = newValue
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
        }
        .padding(12)
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    selection == card.id ? Color.accentColor : Color.white.opacity(0.08),
                    lineWidth: selection == card.id ? 2 : 1
                )
        )
        .position(x: card.x + card.width / 2, y: card.y + card.height / 2)
        .gesture(
            DragGesture()
                .onChanged { value in
                    selection = card.id
                    dragCardID = card.id
                    guard app.canvasDocument.nodes.indices.contains(index) else { return }
                    if dragStart == .zero {
                        dragStart = CGSize(width: card.x, height: card.y)
                    }
                    app.canvasDocument.nodes[index].x = dragStart.width + value.translation.width / scale
                    app.canvasDocument.nodes[index].y = dragStart.height + value.translation.height / scale
                }
                .onEnded { _ in
                    dragCardID = nil
                    dragStart = .zero
                    app.saveCanvas()
                }
        )
        .onTapGesture {
            selection = card.id
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                app.canvasDocument.nodes.removeAll { $0.id == card.id }
                app.canvasDocument.edges.removeAll { $0.from == card.id || $0.to == card.id }
            }
            Button("Link to note…") {
                if let path = app.selectedPath, app.canvasDocument.nodes.indices.contains(index) {
                    app.canvasDocument.nodes[index].type = "file"
                    app.canvasDocument.nodes[index].file = path
                    app.canvasDocument.nodes[index].text = app.vault.notes[path]?.title
                }
            }
        }
    }

    private func groupView(_ group: CanvasGroup) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.05))
                )
            Text(group.label)
                .font(.caption.weight(.semibold))
                .padding(8)
                .foregroundStyle(.secondary)
        }
        .frame(width: group.width, height: group.height)
        .position(x: group.x + group.width / 2, y: group.y + group.height / 2)
    }

    private func arrowView(_ edge: CanvasArrow) -> some View {
        let from = app.canvasDocument.nodes.first { $0.id == edge.from }
        let to = app.canvasDocument.nodes.first { $0.id == edge.to }
        return Group {
            if let from, let to {
                Path { path in
                    let start = CGPoint(x: from.x + from.width / 2, y: from.y + from.height / 2)
                    let end = CGPoint(x: to.x + to.width / 2, y: to.y + to.height / 2)
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }

    private func addCard() {
        let card = CanvasCard(
            id: UUID().uuidString,
            x: 120 + Double.random(in: 0...80),
            y: 120 + Double.random(in: 0...80),
            width: 240,
            height: 130,
            type: "text",
            text: "New card",
            file: nil,
            color: nil
        )
        app.canvasDocument.nodes.append(card)
        selection = card.id
        app.saveCanvas()
    }

    private func addGroup() {
        let group = CanvasGroup(
            id: UUID().uuidString,
            x: 60, y: 60,
            width: 420, height: 280,
            label: "Group",
            color: nil
        )
        app.canvasDocument.groups.append(group)
        app.saveCanvas()
    }

    private func connectSelection() {
        guard let from = selection,
              let to = app.canvasDocument.nodes.first(where: { $0.id != from })?.id
        else { return }
        let edge = CanvasArrow(id: UUID().uuidString, from: from, to: to, label: nil)
        app.canvasDocument.edges.append(edge)
        app.saveCanvas()
    }
}

struct CanvasBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            var path = Path()
            stride(from: 0 as CGFloat, through: size.width, by: step).forEach { x in
                stride(from: 0 as CGFloat, through: size.height, by: step).forEach { y in
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                }
            }
            context.fill(path, with: .color(.secondary.opacity(0.25)))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
