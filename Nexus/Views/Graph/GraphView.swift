import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// World-class interactive graph visualizer — force layout + Canvas rendering,
/// hover focus, pan/zoom, filters, presets, PNG export.
struct GraphView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var engine = GraphViewModel()

    var body: some View {
        HSplitView {
            graphCanvas
                .frame(minWidth: 400)
            GraphControlsPanel(engine: engine)
                .frame(width: 280)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { rebuild() }
        .onChange(of: app.linkIndex.lastBuilt) { _, _ in rebuild() }
        .onChange(of: app.graphMode) { _, _ in rebuild() }
        .onChange(of: app.graphLocalDepth) { _, _ in rebuild() }
        .onChange(of: app.selectedPath) { _, _ in
            if app.graphMode == .local { rebuild() }
        }
        .onChange(of: app.graphShowTags) { _, _ in rebuild() }
        .onChange(of: app.graphShowOrphans) { _, _ in rebuild() }
        .onChange(of: app.graphShowUnresolved) { _, _ in rebuild() }
        .onChange(of: app.graphQuery) { _, _ in rebuild() }
        .onChange(of: app.graphReheat) { _, _ in engine.reheat() }
        .onChange(of: app.graphResetCamera) { _, _ in engine.fitToView() }
        .onChange(of: app.graphPhysics) { _, new in
            engine.physics = new
            engine.simulator.settings = new
            // Live slider tweaks should gently re-run layout, not cold-start.
            engine.reheat(energy: 0.4)
        }
        .onChange(of: app.graphColorBy) { _, new in
            engine.colorMode = new
            engine.refreshAppearance()
        }
        .onChange(of: app.graphLabels) { _, new in
            engine.labelMode = new
            engine.hostView?.needsDisplay = true
        }
        .onChange(of: app.useMetalGraph) { _, new in
            engine.useMetal = new
            engine.hostView?.needsDisplay = true
        }
    }

    private var graphCanvas: some View {
        ZStack(alignment: .topLeading) {
            GraphCanvasRepresentable(engine: engine)
                .clipShape(RoundedRectangle(cornerRadius: 0))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("Mode", selection: $app.graphMode) {
                        Text("Global").tag(GraphViewMode.global)
                        Text("Local").tag(GraphViewMode.local)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    if app.graphMode == .local {
                        Stepper("Depth \(app.graphLocalDepth)", value: $app.graphLocalDepth, in: 1...5)
                            .frame(width: 140)
                    }

                    Spacer()

                    Text(engine.statusText + (engine.metalActive ? " · Metal" : " · CoreGraphics"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(12)

                Spacer()

                if let hover = engine.hoveredInfo {
                    GraphHoverCard(info: hover)
                        .padding(12)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .contextMenu {
            if let id = engine.contextNodeID {
                Button("Open Note") {
                    if !id.hasPrefix("tag:"), !id.hasPrefix("unresolved:") {
                        app.openNote(path: id)
                    }
                }
                Button("Open Local Graph") {
                    app.selectedPath = id
                    app.graphMode = .local
                    app.mainMode = .graph
                }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
            Button("Fit to View") { engine.fitToView() }
            Button("Reheat Layout") { engine.reheat() }
            Button("Export PNG…") { engine.exportPNG() }
        }
    }

    private func rebuild() {
        let snapshot: GraphSnapshot
        switch app.graphMode {
        case .global:
            snapshot = app.linkIndex.globalGraph(
                query: app.graphQuery,
                folders: [],
                tagsFilter: [],
                showTags: app.graphShowTags,
                showAttachments: app.graphShowAttachments,
                showOrphans: app.graphShowOrphans,
                showUnresolved: app.graphShowUnresolved
            )
        case .local:
            let center = app.selectedPath ?? app.linkIndex.graph.nodes.first(where: { $0.kind == .note })?.id ?? ""
            snapshot = app.linkIndex.localGraph(
                center: center,
                depth: app.graphLocalDepth,
                includeTags: app.graphShowTags,
                includeUnresolved: app.graphShowUnresolved,
                includeOrphans: false
            )
        }
        engine.colorMode = app.graphColorBy
        engine.labelMode = app.graphLabels
        engine.physics = app.graphPhysics
        engine.linkThickness = app.graphPhysics.linkThickness
        engine.useMetal = app.useMetalGraph
        let isFirstLoad = engine.renderNodes.isEmpty
        engine.load(snapshot)
        engine.onOpenNode = { id in
            if !id.hasPrefix("tag:"), !id.hasPrefix("unresolved:") {
                app.openNote(path: id)
            }
        }
        // Obsidian-like: frame the graph when first opening or after a full rebuild.
        if isFirstLoad {
            DispatchQueue.main.async {
                engine.fitToView(padding: 0.18)
            }
        }
    }
}

// MARK: - Hover card

struct GraphHoverInfo: Equatable {
    var title: String
    var path: String?
    var kindLabel: String
    var degree: Int
    var folder: String
    var tags: [String]
    var summary: String?
}

private struct GraphHoverCard: View {
    let info: GraphHoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.title)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(info.kindLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                Text("\(info.degree) link\(info.degree == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !info.folder.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(info.folder)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let path = info.path, !path.isEmpty {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let summary = info.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }

            if !info.tags.isEmpty {
                Text(info.tags.prefix(6).map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

// MARK: - View model

final class GraphViewModel: ObservableObject {
    @Published var hoveredInfo: GraphHoverInfo?
    /// Legacy single-line string for any callers; prefer `hoveredInfo`.
    @Published var hoveredLabel: String?
    @Published var statusText = "0 nodes"
    @Published var contextNodeID: String?

    var colorMode: GraphColorMode = .folder
    var labelMode: GraphLabelMode = .hover
    var physics = GraphPhysicsSettings()
    var linkThickness: Double = 1
    var useMetal = true
    var onOpenNode: ((String) -> Void)?

    let simulator = ForceSimulator()
    let metal = MetalGraphRenderer()
    private(set) var renderNodes: [RenderNode] = []
    private(set) var renderEdges: [RenderEdge] = []
    private(set) var snapshot = GraphSnapshot(nodes: [], edges: [])
    /// Adjacency for O(degree) hover neighbor lookup (not O(E)).
    private(set) var adjacency: [String: Set<String>] = [:]
    private var idToIndex: [String: Int] = [:]

    var scale: CGFloat = 1
    var offset: CGSize = .zero
    private var displayLink: CVDisplayLink?
    private var positions: [String: SIMD2<Double>] = [:]
    weak var hostView: GraphNSView?
    private var timer: Timer?

    var metalActive: Bool { useMetal && metal.isAvailable }

    /// Cap drawn edges so huge vaults stay interactive (physics still uses full graph).
    var maxDrawnEdges: Int {
        let e = renderEdges.count
        if e <= 2_500 { return e }
        if e <= 8_000 { return 4_000 }
        return 5_000
    }

    struct RenderNode {
        var id: String
        var label: String
        var kind: GraphNodeKind
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var color: NSColor
        /// Cached device RGB for Metal (avoids NSColor conversion every frame).
        var rgba: (Float, Float, Float, Float)
        var folder: String
        var degree: Int
        var path: String?
        var tags: [String]
        var summary: String?
    }

    struct RenderEdge {
        var source: String
        var target: String
        var sourceIndex: Int
        var targetIndex: Int
        var weight: Double
    }

    func load(_ snapshot: GraphSnapshot) {
        self.snapshot = snapshot
        simulator.settings = physics
        let hadPositions = !positions.isEmpty
        simulator.load(snapshot: snapshot, preservePositions: positions)
        rebuildRenderModel()
        let n = snapshot.nodes.count
        let e = snapshot.edges.count
        let drawn = maxDrawnEdges
        if e > drawn {
            statusText = "\(n) nodes · \(e) links · drawing \(drawn)"
        } else {
            statusText = "\(n) nodes · \(e) links"
        }
        // Fresh graph → allow one auto-fit after the layout starts to open up.
        if !hadPositions {
            didAutoFitThisRun = false
        }
        startLoop()
    }

    func reheat(energy: Double = 1) {
        simulator.settings = physics
        simulator.reheat(energy: energy)
        // Don't thrash the timer if physics is already running (critical during node drag).
        if timer == nil {
            startLoop()
        }
    }

    /// Reset physics knobs + forget stale positions + full re-layout + fit (Obsidian “fresh graph”).
    func applyDefaultPhysicsAndRelayout() {
        physics = GraphPhysicsSettings()
        linkThickness = physics.linkThickness
        positions.removeAll(keepingCapacity: true)
        didAutoFitThisRun = false
        simulator.settings = physics
        simulator.load(snapshot: snapshot, preservePositions: [:])
        rebuildRenderModel()
        startLoop()
        DispatchQueue.main.async { [weak self] in
            self?.fitToView(padding: 0.14)
        }
    }

    /// Identity camera (scale 1, origin). Prefer `fitToView` for Obsidian-like framing.
    func resetCamera() {
        scale = 1
        offset = .zero
        hostView?.needsDisplay = true
    }

    /// Frame the graph in the viewport (Obsidian “zoom to fit”).
    /// Uses a core-aware box so far-flung orphans don’t shrink the main cluster to a speck.
    func fitToView(padding: CGFloat = 0.14) {
        guard let box = simulator.framingBox() ?? simulator.boundingBox(),
              let view = hostView,
              view.bounds.width > 10,
              view.bounds.height > 10
        else {
            resetCamera()
            return
        }
        let worldW = max(box.maxX - box.minX, 40)
        let worldH = max(box.maxY - box.minY, 40)
        let cx = (box.minX + box.maxX) / 2
        let cy = (box.minY + box.maxY) / 2
        let pad = 1 - min(max(padding, 0), 0.4)
        let sx = view.bounds.width * pad / CGFloat(worldW)
        let sy = view.bounds.height * pad / CGFloat(worldH)
        scale = min(max(min(sx, sy), 0.12), 5)
        // Project world center to view center: mid + offset + world*scale = mid ⇒ offset = -world*scale
        offset = CGSize(width: -CGFloat(cx) * scale, height: -CGFloat(cy) * scale)
        hostView?.needsDisplay = true
    }

    /// Live node drag: update simulator + render model immediately so the node follows the cursor.
    func applyNodeDrag(id: String, x: Double, y: Double) {
        simulator.drag(id: id, x: x, y: y)
        positions[id] = SIMD2(x, y)
        if let i = idToIndex[id], i < renderNodes.count {
            renderNodes[i].x = CGFloat(x)
            renderNodes[i].y = CGFloat(y)
        }
        if timer == nil {
            startLoop()
        }
        hostView?.needsDisplay = true
        hostView?.displayIfNeeded()
    }

    func endNodeDrag(id: String) {
        simulator.unpin(id: id)
        simulator.setAlphaTarget(0)
        simulator.reheat(energy: 0.25)
        syncPositionsFromSimulator()
        if timer == nil {
            startLoop()
        }
        hostView?.needsDisplay = true
        hostView?.displayIfNeeded()
    }

    /// Recompute node colors/sizes from the current snapshot without resetting layout.
    func refreshAppearance() {
        rebuildRenderModel()
        hostView?.needsDisplay = true
    }

    func exportPNG() {
        guard let view = hostView else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        guard let rep else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "nexus-graph.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
        }
    }

    private func startLoop() {
        stopLoop()
        // Adaptive rate: huge graphs can't pay for 60 full force+draw frames.
        let e = max(snapshot.edges.count, renderEdges.count)
        let n = max(snapshot.nodes.count, renderNodes.count)
        let hz: Double
        if e > 8_000 || n > 2_000 {
            hz = 24
        } else if e > 2_500 || n > 600 {
            hz = 30
        } else {
            hz = 60
        }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        // Persist positions when the sim settles (for layout continuity).
        positions = simulator.positions()
    }

    private var didAutoFitThisRun = false

    private func tick() {
        simulator.settings = physics
        // Large graphs: two cheap spatial steps per frame instead of one expensive rebuild.
        let heavy = snapshot.edges.count > 2_500 || snapshot.nodes.count > 600
        var active = simulator.step()
        if heavy, active {
            active = simulator.step() || active
        }
        syncPositionsFromSimulator()
        hostView?.needsDisplay = true
        if !didAutoFitThisRun, simulator.alpha < 0.45, simulator.alphaTarget == 0 {
            didAutoFitThisRun = true
            fitToView(padding: 0.16)
        }
        if !active {
            stopLoop()
        }
    }

    /// Hot path: only copy x/y from the simulator (order matches snapshot.nodes).
    private func syncPositionsFromSimulator() {
        let sim = simulator.nodes
        let count = min(sim.count, renderNodes.count)
        for i in 0..<count {
            renderNodes[i].x = CGFloat(sim[i].x)
            renderNodes[i].y = CGFloat(sim[i].y)
        }
    }

    private func rebuildRenderModel() {
        let pos = simulator.positions()
        idToIndex.removeAll(keepingCapacity: true)
        var adj: [String: Set<String>] = [:]
        adj.reserveCapacity(snapshot.nodes.count)

        renderNodes = snapshot.nodes.enumerated().map { idx, n in
            idToIndex[n.id] = idx
            let p = pos[n.id] ?? SIMD2(n.x, n.y)
            let radius = 4 + min(CGFloat(n.degree), 40) * 0.55
            let col = color(for: n)
            return RenderNode(
                id: n.id,
                label: n.label,
                kind: n.kind,
                x: CGFloat(p.x),
                y: CGFloat(p.y),
                radius: radius,
                color: col,
                rgba: rgbaTuple(col),
                folder: n.folder,
                degree: n.degree,
                path: n.path ?? (n.kind == .note ? n.id : nil),
                tags: n.tags,
                summary: n.summary
            )
        }

        // Sort edges by weight desc so LOD keeps the most important links.
        let sorted = snapshot.edges.sorted { $0.weight > $1.weight }
        renderEdges = sorted.compactMap { e in
            guard let si = idToIndex[e.source], let ti = idToIndex[e.target] else { return nil }
            adj[e.source, default: []].insert(e.target)
            adj[e.target, default: []].insert(e.source)
            return RenderEdge(
                source: e.source,
                target: e.target,
                sourceIndex: si,
                targetIndex: ti,
                weight: e.weight
            )
        }
        adjacency = adj
    }

    private func rgbaTuple(_ ns: NSColor) -> (Float, Float, Float, Float) {
        let c = ns.usingColorSpace(.deviceRGB) ?? ns
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Float(r), Float(g), Float(b), Float(a))
    }

    /// Edges to paint this frame (LOD + hover-priority). Physics still uses full edge list.
    func edgesForDraw(hovered: String?) -> [RenderEdge] {
        let budget = maxDrawnEdges
        if renderEdges.count <= budget { return renderEdges }
        var out: [RenderEdge] = []
        out.reserveCapacity(budget)
        var used = Set<Int>()
        if let h = hovered {
            for (i, e) in renderEdges.enumerated() where e.source == h || e.target == h {
                out.append(e)
                used.insert(i)
                if out.count >= budget { return out }
            }
        }
        // Already weight-sorted: take top remaining.
        for (i, e) in renderEdges.enumerated() where !used.contains(i) {
            out.append(e)
            if out.count >= budget { break }
        }
        return out
    }

    private func color(for node: GraphNode) -> NSColor {
        switch node.kind {
        case .tag:
            return NSColor(calibratedRed: 0.72, green: 0.55, blue: 1.0, alpha: 1)
        case .unresolved:
            return NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.5, alpha: 0.7)
        case .attachment:
            return NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.7, alpha: 1)
        case .note:
            switch colorMode {
            case .folder:
                return paletteColor(hash: node.folder.hashValue)
            case .tag:
                return paletteColor(hash: (node.tags.first ?? node.label).hashValue)
            case .degree:
                let t = min(Double(node.degree) / 20.0, 1)
                return NSColor(calibratedRed: 0.35 + t * 0.5, green: 0.55, blue: 1.0 - t * 0.3, alpha: 1)
            }
        }
    }

    private func paletteColor(hash: Int) -> NSColor {
        let hues: [CGFloat] = [0.58, 0.72, 0.08, 0.35, 0.48, 0.90, 0.15, 0.62]
        let h = hues[abs(hash) % hues.count]
        return NSColor(calibratedHue: h, saturation: 0.45, brightness: 0.85, alpha: 1)
    }

    deinit {
        // CVDisplayLink stop on main is safer; ignore if already gone
    }
}

// MARK: - AppKit canvas host

struct GraphCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var engine: GraphViewModel

    func makeNSView(context: Context) -> GraphNSView {
        let view = GraphNSView()
        view.engine = engine
        engine.hostView = view
        return view
    }

    func updateNSView(_ nsView: GraphNSView, context: Context) {
        nsView.engine = engine
        engine.hostView = nsView
        nsView.needsDisplay = true
    }
}

final class GraphNSView: NSView {
    weak var engine: GraphViewModel?

    private var isPanning = false
    private var lastPan: CGPoint = .zero
    private var draggingNode: String?
    private var mouseDownPoint: CGPoint = .zero
    private var didDragPastThreshold = false
    private var hovered: String?
    private var neighbors: Set<String> = []
    private var trackingArea: NSTrackingArea?
    private var metalAttached = false

    /// Pixels of movement before a press is treated as drag (not a click).
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { !(engine?.metalActive ?? false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        attachMetalIfNeeded()
    }

    override func layout() {
        super.layout()
        attachMetalIfNeeded()
        let scale = window?.backingScaleFactor ?? 2
        engine?.metal.resize(to: bounds, scale: scale)
    }

    private func attachMetalIfNeeded() {
        guard !metalAttached, let engine, engine.metal.isAvailable else { return }
        if engine.metal.attach(to: self) != nil {
            metalAttached = true
            let scale = window?.backingScaleFactor ?? 2
            engine.metal.resize(to: bounds, scale: scale)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .mouseEnteredAndExited,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            neighbors = []
            engine?.hoveredLabel = nil
            engine?.hoveredInfo = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let engine, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let scale = engine.scale
        let ox = bounds.midX + engine.offset.width
        let oy = bounds.midY + engine.offset.height
        let nodes = engine.renderNodes
        let drawEdges = engine.edgesForDraw(hovered: hovered)
        let fadeOthers = hovered != nil

        func project(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * scale, y: oy + y * scale)
        }

        // Metal path: GPU nodes/edges; CoreGraphics only for labels.
        if engine.metalActive {
            attachMetalIfNeeded()
            let ok = engine.metal.draw(
                nodes: nodes,
                edges: drawEdges,
                scale: scale,
                offset: engine.offset,
                viewSize: bounds.size,
                hovered: hovered,
                neighbors: neighbors,
                linkThickness: engine.linkThickness
            )
            if ok {
                drawLabels(ctx: ctx, engine: engine, project: project, fadeOthers: fadeOthers)
                return
            }
        }

        // CoreGraphics fallback — LOD edges + nodes
        ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor)
        ctx.fill(bounds)

        for edge in drawEdges {
            let si = edge.sourceIndex
            let ti = edge.targetIndex
            guard si >= 0, ti >= 0, si < nodes.count, ti < nodes.count else { continue }
            let s = nodes[si]
            let t = nodes[ti]
            let p1 = project(s.x, s.y)
            let p2 = project(t.x, t.y)

            var alpha: CGFloat = 0.22
            if fadeOthers {
                if let h = hovered, edge.source == h || edge.target == h {
                    alpha = 0.75
                } else {
                    alpha = 0.04
                }
            }

            ctx.setStrokeColor(NSColor(calibratedWhite: 0.75, alpha: alpha).cgColor)
            ctx.setLineWidth(max(0.6, CGFloat(edge.weight) * CGFloat(engine.linkThickness) * 0.9))
            ctx.beginPath()
            ctx.move(to: p1)
            ctx.addLine(to: p2)
            ctx.strokePath()
        }

        for node in nodes {
            let p = project(node.x, node.y)
            var alpha: CGFloat = 1
            if fadeOthers {
                if node.id == hovered || neighbors.contains(node.id) {
                    alpha = 1
                } else {
                    alpha = 0.12
                }
            }

            let r = max(3, node.radius * (scale < 0.5 ? 0.8 : 1))
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            ctx.setFillColor(node.color.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: rect)

            if node.degree > 8 && alpha > 0.5 {
                ctx.setStrokeColor(node.color.withAlphaComponent(0.25 * alpha).cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: rect.insetBy(dx: -2, dy: -2))
            }
        }

        drawLabels(ctx: ctx, engine: engine, project: project, fadeOthers: fadeOthers)
    }

    private func drawLabels(
        ctx: CGContext,
        engine: GraphViewModel,
        project: (CGFloat, CGFloat) -> CGPoint,
        fadeOthers: Bool
    ) {
        let scale = engine.scale
        let labels = engine.labelMode
        // Large graphs: never paint every label — hover / neighbor only (Obsidian does similar).
        let large = engine.renderNodes.count > 250
        for node in engine.renderNodes {
            let p = project(node.x, node.y)
            var alpha: CGFloat = 1
            if fadeOthers {
                if node.id == hovered || neighbors.contains(node.id) {
                    alpha = 1
                } else {
                    alpha = 0.12
                }
            }
            let r = max(3, node.radius * (scale < 0.5 ? 0.8 : 1))
            let showLabel: Bool = {
                if large {
                    // Cap label draw calls on big vaults.
                    return node.id == hovered || (fadeOthers && neighbors.contains(node.id))
                }
                switch labels {
                case .always: return scale > 0.45
                case .hover: return node.id == hovered || (fadeOthers && neighbors.contains(node.id) && scale > 0.6)
                case .never: return false
                }
            }()
            if showLabel {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(9, 11 * min(scale, 1.2)), weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(alpha * 0.92)
                ]
                let str = NSAttributedString(string: node.label, attributes: attrs)
                let size = str.size()
                str.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y + r + 3))
            }
        }
        _ = ctx
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        didDragPastThreshold = false

        if event.modifierFlags.contains(.command) || hitNode(at: p) == nil {
            isPanning = true
            lastPan = p
            draggingNode = nil
        } else if let id = hitNode(at: p) {
            // Defer pin/drag until movement exceeds threshold so click can open notes.
            draggingNode = id
            isPanning = false
        }
        engine?.contextNodeID = hitNode(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let engine else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dist = hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y)
        if dist > dragThreshold {
            didDragPastThreshold = true
        }

        if let id = draggingNode {
            guard didDragPastThreshold else { return }
            let w = world(p)
            // Rebuild render positions every move so Metal/CG follow the cursor in real time.
            // (Previously only the simulator was updated; the display loop was also restarted
            // on every drag event, so ticks never painted until mouse-up — the "snap" bug.)
            engine.applyNodeDrag(id: id, x: w.x, y: w.y)
        } else if isPanning {
            let dx = p.x - lastPan.x
            let dy = p.y - lastPan.y
            engine.offset.width += dx
            engine.offset.height += dy
            lastPan = p
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let clickedNode = draggingNode
        if let id = clickedNode, didDragPastThreshold {
            engine?.endNodeDrag(id: id)
        }

        // Click (no drag past threshold) on a node opens the note.
        // Background pan / node drag do not open.
        if !didDragPastThreshold, let id = clickedNode {
            engine?.onOpenNode?(id)
        }

        draggingNode = nil
        isPanning = false
        didDragPastThreshold = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        engine?.contextNodeID = hitNode(at: p)
        // let context menu handle the rest
        super.rightMouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let id = hitNode(at: p)
        if id != hovered {
            hovered = id
            if let id, let node = engine?.renderNodes.first(where: { $0.id == id }) {
                let kindLabel: String = {
                    switch node.kind {
                    case .note: return "Note"
                    case .tag: return "Tag"
                    case .attachment: return "File"
                    case .unresolved: return "Missing"
                    }
                }()
                let info = GraphHoverInfo(
                    title: node.label,
                    path: node.path,
                    kindLabel: kindLabel,
                    degree: node.degree,
                    folder: node.folder,
                    tags: node.tags,
                    summary: node.summary
                )
                engine?.hoveredInfo = info
                var line = "\(node.label)  ·  \(node.degree) links"
                if let s = node.summary, !s.isEmpty {
                    line += "  ·  \(s)"
                }
                engine?.hoveredLabel = line
                neighbors = neighborSet(of: id)
            } else {
                engine?.hoveredLabel = nil
                engine?.hoveredInfo = nil
                neighbors = []
            }
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let engine else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Obsidian-like:
        //  • Pinch / magnify → zoom (handled in magnify)
        //  • Scroll wheel / two-finger vertical → zoom toward cursor
        //  • Shift+scroll or primarily horizontal trackpad → pan
        //  • Option+scroll → pan (escape hatch if you want to move without zooming)
        let isPrecise = event.hasPreciseScrollingDeltas
        let horizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.25
        let wantPan = event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.shift)
            || horizontalDominant

        if wantPan {
            let dx = isPrecise ? event.scrollingDeltaX : event.scrollingDeltaX * 4
            let dy = isPrecise ? event.scrollingDeltaY : event.scrollingDeltaY * 4
            engine.offset.width += dx
            engine.offset.height += dy
            needsDisplay = true
            return
        }

        // Zoom toward cursor. Precise trackpad deltas are larger; scale gently.
        let dy = event.scrollingDeltaY
        let factor: CGFloat
        if isPrecise {
            factor = 1 + dy * 0.0035
        } else {
            factor = 1 + dy * 0.08
        }
        if abs(factor - 1) > 0.0001 {
            zoom(by: factor, around: point)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    private func zoom(by factor: CGFloat, around point: CGPoint) {
        guard let engine else { return }
        let old = engine.scale
        let new = min(max(old * factor, 0.05), 8)
        // Zoom toward cursor
        let wx = (point.x - bounds.midX - engine.offset.width) / old
        let wy = (point.y - bounds.midY - engine.offset.height) / old
        engine.scale = new
        engine.offset.width = point.x - bounds.midX - wx * new
        engine.offset.height = point.y - bounds.midY - wy * new
        needsDisplay = true
    }

    private func world(_ p: CGPoint) -> (x: Double, y: Double) {
        guard let engine else { return (0, 0) }
        let x = (p.x - bounds.midX - engine.offset.width) / engine.scale
        let y = (p.y - bounds.midY - engine.offset.height) / engine.scale
        return (Double(x), Double(y))
    }

    private func hitNode(at p: CGPoint) -> String? {
        guard let engine else { return nil }
        let scale = engine.scale
        let ox = bounds.midX + engine.offset.width
        let oy = bounds.midY + engine.offset.height
        // reverse iterate for topmost
        for node in engine.renderNodes.reversed() {
            let px = ox + node.x * scale
            let py = oy + node.y * scale
            let r = max(6, node.radius * scale + 4)
            let dx = p.x - px
            let dy = p.y - py
            if dx * dx + dy * dy <= r * r {
                return node.id
            }
        }
        return nil
    }

    private func neighborSet(of id: String) -> Set<String> {
        engine?.adjacency[id] ?? []
    }
}

// MARK: - Controls

struct GraphControlsPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var engine: GraphViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Graph")
                    .font(.headline)

                GroupBox("Filters") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Filter notes…", text: $app.graphQuery)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Show orphans", isOn: $app.graphShowOrphans)
                        Toggle("Show tags", isOn: $app.graphShowTags)
                        Toggle("Show unresolved", isOn: $app.graphShowUnresolved)
                        Toggle("Show attachments", isOn: $app.graphShowAttachments)
                    }
                    .padding(4)
                }

                GroupBox("Display") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Color by", selection: $app.graphColorBy) {
                            ForEach(GraphColorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Picker("Labels", selection: $app.graphLabels) {
                            ForEach(GraphLabelMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Toggle("Metal renderer", isOn: $app.useMetalGraph)
                            .help("GPU nodes/edges via Metal; falls back to CoreGraphics if unavailable")
                        HStack {
                            Text("Link thickness")
                            Slider(value: $app.graphPhysics.linkThickness, in: 0.4...3)
                        }
                    }
                    .padding(4)
                }

                GroupBox("Physics") {
                    VStack(alignment: .leading, spacing: 8) {
                        slider("Repulsion", value: $app.graphPhysics.repulsion, range: 400...8000)
                        slider("Center (fit COM)", value: $app.graphPhysics.centerForce, range: 0...1)
                        slider("Spring length", value: $app.graphPhysics.springLength, range: 40...280)
                        slider("Spring strength", value: $app.graphPhysics.springStrength, range: 0.005...0.12)
                        slider("Damping", value: $app.graphPhysics.damping, range: 0.4...0.92)
                        slider("Animation", value: $app.graphPhysics.animationStrength, range: 0.2...2)
                        HStack {
                            Button("Reheat") { engine.reheat() }
                            Button("Fit to view") { engine.fitToView() }
                            Button("Defaults") {
                                app.graphPhysics = GraphPhysicsSettings()
                                engine.applyDefaultPhysicsAndRelayout()
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Presets") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(app.graphPresets) { preset in
                            Button(preset.name) {
                                app.graphShowTags = preset.showTags
                                app.graphShowOrphans = preset.showOrphans
                                app.graphShowUnresolved = preset.showUnresolved
                                app.graphQuery = preset.query
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        Button("Save current as preset…") {
                            savePreset()
                        }
                        .padding(.top, 4)
                    }
                    .padding(4)
                }

                GroupBox("Export") {
                    Button("Export PNG…") { engine.exportPNG() }
                        .padding(4)
                }

                Text("Scroll zoom · Shift/⌥scroll pan · Drag empty space pan · Drag nodes · Click open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Graph Preset"
        alert.informativeText = "Name this filter preset:"
        let field = NSTextField(string: "My preset")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let preset = GraphPreset(
                id: UUID().uuidString,
                name: name,
                showTags: app.graphShowTags,
                showOrphans: app.graphShowOrphans,
                showUnresolved: app.graphShowUnresolved,
                query: app.graphQuery
            )
            app.graphPresets.append(preset)
        }
    }
}
