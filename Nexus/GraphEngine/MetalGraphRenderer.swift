import Foundation
import Metal
import MetalKit
import QuartzCore
import AppKit
import simd

/// GPU-accelerated node/edge drawer for the graph view.
/// CPU force layout stays in `ForceSimulator`; this only paints.
/// Falls back gracefully when Metal is unavailable.
final class MetalGraphRenderer {
    private(set) var isAvailable = false

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipelinePoints: MTLRenderPipelineState?
    private var pipelineLines: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?

    /// Packed layout matching Metal `VertexBuf` (no Swift padding surprises).
    private struct Vertex {
        var x: Float
        var y: Float
        var r: Float
        var g: Float
        var b: Float
        var a: Float
        var pointSize: Float
        var pad: Float = 0
    }

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }

        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            pipelinePoints = try device.makeRenderPipelineState(descriptor: desc)

            desc.vertexFunction = library.makeFunction(name: "vertex_line")
            desc.fragmentFunction = library.makeFunction(name: "fragment_solid")
            pipelineLines = try device.makeRenderPipelineState(descriptor: desc)

            isAvailable = true
        } catch {
            isAvailable = false
            #if DEBUG
            print("MetalGraphRenderer init failed: \(error)")
            #endif
        }
    }

    func attach(to view: NSView) -> CAMetalLayer? {
        guard isAvailable, let device else { return nil }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.wantsLayer = true
        // Keep under any future overlays; we draw labels with CoreGraphics after present if needed.
        if let existing = view.layer {
            existing.addSublayer(layer)
        } else {
            view.layer = layer
        }
        metalLayer = layer
        return layer
    }

    func resize(to bounds: CGRect, scale: CGFloat) {
        guard let metalLayer else { return }
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    // Reused CPU vertex scratch (avoids realloc thrash on large graphs).
    private var lineScratch: [Vertex] = []
    private var pointScratch: [Vertex] = []

    /// Draw edges + nodes into the Metal layer. Returns false if Metal path unavailable.
    @discardableResult
    func draw(
        nodes: [GraphViewModel.RenderNode],
        edges: [GraphViewModel.RenderEdge],
        scale: CGFloat,
        offset: CGSize,
        viewSize: CGSize,
        hovered: String?,
        neighbors: Set<String>,
        linkThickness: Double
    ) -> Bool {
        guard isAvailable,
              let metalLayer,
              let queue,
              let pipelineLines,
              let pipelinePoints,
              let drawable = metalLayer.nextDrawable()
        else { return false }

        let width = Float(viewSize.width)
        let height = Float(viewSize.height)
        guard width > 1, height > 1 else { return false }

        let ox = Float(viewSize.width / 2 + offset.width)
        let oy = Float(viewSize.height / 2 + offset.height)
        let s = Float(scale)
        let fade = hovered != nil
        // Viewport cull margin in screen px (keep edges that clip the frame).
        let margin: Float = 40
        let minX: Float = -margin
        let maxX: Float = width + margin
        let minY: Float = -margin
        let maxY: Float = height + margin

        @inline(__always)
        func project(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
            SIMD2(ox + Float(x) * s, oy + Float(y) * s)
        }

        @inline(__always)
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(
                (p.x / width) * 2 - 1,
                1 - (p.y / height) * 2
            )
        }

        @inline(__always)
        func inView(_ p: SIMD2<Float>) -> Bool {
            p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
        }

        // Edges — index lookup + frustum cull (both endpoints off-screen ⇒ skip).
        lineScratch.removeAll(keepingCapacity: true)
        lineScratch.reserveCapacity(min(edges.count, 8_000) * 2)
        let edgeR: Float = 0.75
        let edgeG: Float = 0.75
        let edgeB: Float = 0.75
        for edge in edges {
            let si = edge.sourceIndex
            let ti = edge.targetIndex
            guard si >= 0, ti >= 0, si < nodes.count, ti < nodes.count else { continue }
            let a = nodes[si]
            let b = nodes[ti]
            let sp = project(a.x, a.y)
            let tp = project(b.x, b.y)
            if !inView(sp), !inView(tp) {
                // Cheap reject: both ends outside the same half-plane.
                if (sp.x < minX && tp.x < minX) || (sp.x > maxX && tp.x > maxX)
                    || (sp.y < minY && tp.y < minY) || (sp.y > maxY && tp.y > maxY) {
                    continue
                }
            }
            var alpha: Float = 0.22
            if fade {
                if let h = hovered, edge.source == h || edge.target == h {
                    alpha = 0.75
                } else {
                    alpha = 0.04
                }
            }
            // Slight thickness cue for multi-links without extra geometry.
            alpha = min(1, alpha * Float(0.85 + min(edge.weight, 3) * 0.08 * linkThickness))
            let p1 = ndc(sp)
            let p2 = ndc(tp)
            lineScratch.append(Vertex(x: p1.x, y: p1.y, r: edgeR, g: edgeG, b: edgeB, a: alpha, pointSize: 1))
            lineScratch.append(Vertex(x: p2.x, y: p2.y, r: edgeR, g: edgeG, b: edgeB, a: alpha, pointSize: 1))
        }

        // Nodes — use pre-baked RGBA (no NSColor work on the hot path).
        pointScratch.removeAll(keepingCapacity: true)
        pointScratch.reserveCapacity(nodes.count)
        let contentsScale = Float(metalLayer.contentsScale)
        for node in nodes {
            var alpha: Float = 1
            if fade {
                if node.id == hovered || neighbors.contains(node.id) {
                    alpha = 1
                } else {
                    alpha = 0.12
                }
            }
            let p = ndc(project(node.x, node.y))
            let radius = max(3, node.radius * (scale < 0.5 ? 0.8 : 1))
            let pointSize = Float(radius * 2) * contentsScale
            let (r, g, bl, baseA) = node.rgba
            pointScratch.append(Vertex(
                x: p.x, y: p.y, r: r, g: g, b: bl, a: alpha * baseA,
                pointSize: max(4, pointSize)
            ))
        }

        let lineVerts = lineScratch
        let pointVerts = pointScratch

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return false }

        if !lineVerts.isEmpty, let buf = device?.makeBuffer(
            bytes: lineVerts,
            length: MemoryLayout<Vertex>.stride * lineVerts.count,
            options: .storageModeShared
        ) {
            enc.setRenderPipelineState(pipelineLines)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            // Approximate thickness via multiple draws is overkill; single hairline is fine.
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVerts.count)
            _ = linkThickness
        }

        if !pointVerts.isEmpty, let buf = device?.makeBuffer(
            bytes: pointVerts,
            length: MemoryLayout<Vertex>.stride * pointVerts.count,
            options: .storageModeShared
        ) {
            enc.setRenderPipelineState(pipelinePoints)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointVerts.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float  pointSize [[point_size]];
    };

    struct VertexBuf {
        float x;
        float y;
        float r;
        float g;
        float b;
        float a;
        float pointSize;
        float pad;
    };

    vertex VertexOut vertex_main(uint vid [[vertex_id]],
                                 const device VertexBuf *vertices [[buffer(0)]]) {
        VertexBuf v = vertices[vid];
        VertexOut out;
        out.position = float4(v.x, v.y, 0, 1);
        out.color = float4(v.r, v.g, v.b, v.a);
        out.pointSize = v.pointSize;
        return out;
    }

    vertex VertexOut vertex_line(uint vid [[vertex_id]],
                                 const device VertexBuf *vertices [[buffer(0)]]) {
        VertexBuf v = vertices[vid];
        VertexOut out;
        out.position = float4(v.x, v.y, 0, 1);
        out.color = float4(v.r, v.g, v.b, v.a);
        out.pointSize = 1.0;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  float2 pc [[point_coord]]) {
        // Soft circular points (also used for lines — point_coord is 0..1; lines ignore shape)
        float2 c = pc - float2(0.5);
        float d = length(c);
        float alpha = in.color.a;
        // When drawing lines, Metal still supplies point_coord; keep full alpha near center path.
        if (d > 0.5) {
            discard_fragment();
        }
        alpha *= smoothstep(0.5, 0.3, d);
        return float4(in.color.rgb, alpha);
    }

    fragment float4 fragment_solid(VertexOut in [[stage_in]]) {
        return in.color;
    }
    """
}
