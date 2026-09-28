import Foundation
import Metal
import MetalKit
import QuartzCore
import AppKit
import simd

/// GPU-accelerated node/edge drawer for the graph view.
/// - Nodes: point sprites (instanced-style single buffer draw)
/// - Edges: **triangle quads** for true thickness (not hairlines)
/// CPU force layout stays in `ForceSimulator`; this only paints.
final class MetalGraphRenderer {
    private(set) var isAvailable = false

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipelinePoints: MTLRenderPipelineState?
    private var pipelineTris: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?

    /// Packed layout matching Metal `VertexBuf`.
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

            desc.vertexFunction = library.makeFunction(name: "vertex_solid")
            desc.fragmentFunction = library.makeFunction(name: "fragment_solid")
            pipelineTris = try device.makeRenderPipelineState(descriptor: desc)

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

    private var triScratch: [Vertex] = []
    private var pointScratch: [Vertex] = []
    /// Cap triangle vertices (~6 per edge) for huge graphs — LOD keeps top-weight edges.
    private let maxEdgeQuads = 6_000

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
              let pipelineTris,
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

        // --- Edges as thick quads (2 triangles = 6 verts) ---
        triScratch.removeAll(keepingCapacity: true)
        let edgeBudget = min(edges.count, maxEdgeQuads)
        triScratch.reserveCapacity(edgeBudget * 6)

        let baseHalfWidth = max(0.35, Float(linkThickness) * 0.55) // screen px half-thickness
        let edgeR: Float = 0.72
        let edgeG: Float = 0.74
        let edgeB: Float = 0.78

        var drawnEdges = 0
        for edge in edges {
            if drawnEdges >= maxEdgeQuads { break }
            let si = edge.sourceIndex
            let ti = edge.targetIndex
            guard si >= 0, ti >= 0, si < nodes.count, ti < nodes.count else { continue }
            let a = nodes[si]
            let b = nodes[ti]
            let sp = project(a.x, a.y)
            let tp = project(b.x, b.y)
            if !inView(sp), !inView(tp) {
                if (sp.x < minX && tp.x < minX) || (sp.x > maxX && tp.x > maxX)
                    || (sp.y < minY && tp.y < minY) || (sp.y > maxY && tp.y > maxY) {
                    continue
                }
            }

            // Keep non-focus edges readable — heavy dim made unhover feel like the map "exploded".
            var alpha: Float = 0.28
            if fade {
                if let h = hovered, edge.source == h || edge.target == h {
                    alpha = 0.9
                } else {
                    alpha = 0.12
                }
            }
            alpha = min(1, alpha * Float(0.9 + min(edge.weight, 4) * 0.06))

            // Perpendicular in screen space
            let dx = tp.x - sp.x
            let dy = tp.y - sp.y
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            let half = baseHalfWidth * Float(0.85 + min(edge.weight, 3) * 0.15) * max(0.7, min(1.4, s))
            let nx = (-dy / len) * half
            let ny = (dx / len) * half

            // Quad corners in screen px → NDC
            let s1 = ndc(SIMD2(sp.x + nx, sp.y + ny))
            let s2 = ndc(SIMD2(sp.x - nx, sp.y - ny))
            let t1 = ndc(SIMD2(tp.x + nx, tp.y + ny))
            let t2 = ndc(SIMD2(tp.x - nx, tp.y - ny))

            func v(_ p: SIMD2<Float>) -> Vertex {
                Vertex(x: p.x, y: p.y, r: edgeR, g: edgeG, b: edgeB, a: alpha, pointSize: 1)
            }
            // Triangle 1: s1, s2, t1
            triScratch.append(v(s1))
            triScratch.append(v(s2))
            triScratch.append(v(t1))
            // Triangle 2: s2, t2, t1
            triScratch.append(v(s2))
            triScratch.append(v(t2))
            triScratch.append(v(t1))
            drawnEdges += 1
        }

        // --- Nodes (single drawPrimitives — GPU batches as instanced points) ---
        pointScratch.removeAll(keepingCapacity: true)
        pointScratch.reserveCapacity(nodes.count)
        let contentsScale = Float(metalLayer.contentsScale)
        for node in nodes {
            var alpha: Float = 1
            if fade {
                if node.id == hovered || neighbors.contains(node.id) {
                    alpha = 1
                } else {
                    alpha = 0.55
                }
            }
            let p = ndc(project(node.x, node.y))
            // Skip far off-screen nodes for large vaults
            if p.x < -1.2 || p.x > 1.2 || p.y < -1.2 || p.y > 1.2 {
                // keep hubs (high degree) even if slightly off-screen for continuity
                if node.degree < 8 { continue }
            }
            let radius = max(3, node.radius * (scale < 0.5 ? 0.8 : 1))
            let pointSize = Float(radius * 2) * contentsScale
            let (r, g, bl, baseA) = node.rgba
            pointScratch.append(Vertex(
                x: p.x, y: p.y, r: r, g: g, b: bl, a: alpha * baseA,
                pointSize: max(4, pointSize)
            ))
        }

        let triVerts = triScratch
        let pointVerts = pointScratch

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return false }

        if !triVerts.isEmpty, let buf = device?.makeBuffer(
            bytes: triVerts,
            length: MemoryLayout<Vertex>.stride * triVerts.count,
            options: .storageModeShared
        ) {
            enc.setRenderPipelineState(pipelineTris)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triVerts.count)
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

    vertex VertexOut vertex_solid(uint vid [[vertex_id]],
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
        float2 c = pc - float2(0.5);
        float d = length(c);
        float alpha = in.color.a;
        if (d > 0.5) {
            discard_fragment();
        }
        alpha *= smoothstep(0.5, 0.28, d);
        return float4(in.color.rgb, alpha);
    }

    fragment float4 fragment_solid(VertexOut in [[stage_in]]) {
        return in.color;
    }
    """
}
