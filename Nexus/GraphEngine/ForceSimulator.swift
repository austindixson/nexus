import Foundation
import simd

/// Force-directed layout modeled after d3-force / Obsidian graph behavior.
///
/// Design notes (why this no longer shrinks *or* flings orphans to infinity):
/// - **Center** is a COM *translation* (structure-preserving), not a radial crush.
/// - **Many-body** uses a **distanceMax** (d3) so far-away isolates stop accelerating outward.
/// - **Weak radial tether** keeps the whole cloud in a readable disc (Obsidian-like).
/// - **Collision** prevents stacking; **link springs** use a stable rest length.
final class ForceSimulator {
    struct NodeState {
        var id: String
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var mass: Double
        var radius: Double
        var degree: Int
        var pinned: Bool
    }

    struct EdgeState {
        var source: Int
        var target: Int
        var weight: Double
    }

    private(set) var nodes: [NodeState] = []
    private var edges: [EdgeState] = []
    private var idToIndex: [String: Int] = [:]

    var settings = GraphPhysicsSettings()

    /// Simulation “temperature” (d3-force α). Forces scale with this; it cools toward `alphaMin`.
    var alpha: Double = 1.0
    /// While > 0, α reheats toward this target each tick (used during drag).
    var alphaTarget: Double = 0
    var alphaDecay: Double = 0.0228 // ~300 ticks to cool
    var alphaMin: Double = 0.001

    func load(snapshot: GraphSnapshot, preservePositions: [String: SIMD2<Double>] = [:]) {
        idToIndex.removeAll(keepingCapacity: true)
        var preserved = 0
        let count = max(snapshot.nodes.count, 1)

        // Degree from snapshot (edges may filter some ids).
        var degreeMap: [String: Int] = [:]
        for n in snapshot.nodes { degreeMap[n.id] = n.degree }

        nodes = snapshot.nodes.enumerated().map { idx, n in
            idToIndex[n.id] = idx
            let degree = degreeMap[n.id] ?? n.degree
            let radius = 4.0 + min(Double(degree), 40) * 0.55
            if let pos = preservePositions[n.id] {
                preserved += 1
                return NodeState(
                    id: n.id,
                    x: pos.x, y: pos.y,
                    vx: 0, vy: 0,
                    mass: max(1.0, Double(degree) * 0.35 + 1.0),
                    radius: radius,
                    degree: degree,
                    pinned: n.pinned
                )
            }
            // Disc seed — connected notes on an inner ring, isolates on an outer ring
            // so the first frames already look like Obsidian’s “cloud + shell”.
            let angle = (Double(idx) / Double(count)) * .pi * 2 + Double.random(in: -0.08...0.08)
            let isIsolate = degree == 0
            let ring = isIsolate
                ? (160.0 + Double(idx % 7) * 18.0)
                : (50.0 + Double(idx % 9) * 22.0)
            let jitter = Double.random(in: -12...12)
            return NodeState(
                id: n.id,
                x: cos(angle) * (ring + jitter),
                y: sin(angle) * (ring + jitter),
                vx: 0, vy: 0,
                mass: max(1.0, Double(degree) * 0.35 + 1.0),
                radius: radius,
                degree: degree,
                pinned: n.pinned
            )
        }
        edges = snapshot.edges.compactMap { e in
            guard let s = idToIndex[e.source], let t = idToIndex[e.target] else { return nil }
            return EdgeState(source: s, target: t, weight: e.weight)
        }

        let ratio = nodes.isEmpty ? 0 : Double(preserved) / Double(nodes.count)
        alpha = ratio > 0.6 ? 0.4 : 1.0
        alphaTarget = 0
    }

    func reheat(energy: Double = 1.0) {
        alpha = min(1.0, max(alpha, energy))
        alphaTarget = 0
    }

    func setAlphaTarget(_ target: Double) {
        alphaTarget = min(1.0, max(0, target))
        if target > 0 {
            alpha = max(alpha, target)
        }
    }

    func pin(id: String, x: Double, y: Double) {
        guard let i = idToIndex[id] else { return }
        nodes[i].x = x
        nodes[i].y = y
        nodes[i].vx = 0
        nodes[i].vy = 0
        nodes[i].pinned = true
    }

    func unpin(id: String) {
        guard let i = idToIndex[id] else { return }
        nodes[i].pinned = false
    }

    func drag(id: String, x: Double, y: Double) {
        guard let i = idToIndex[id] else { return }
        nodes[i].x = x
        nodes[i].y = y
        nodes[i].vx = 0
        nodes[i].vy = 0
        nodes[i].pinned = true
        alpha = max(alpha, 0.25)
        alphaTarget = 0.12
    }

    @discardableResult
    func step() -> Bool {
        guard !nodes.isEmpty else { return false }

        alpha += (alphaTarget - alpha) * alphaDecay
        guard alpha >= alphaMin || alphaTarget > 0 else { return false }

        let n = nodes.count
        let anim = max(0.05, settings.animationStrength)
        let charge = -abs(settings.repulsion) * anim
        let springK = settings.springStrength * anim
        let rest = max(settings.springLength, 1)
        // Cap long-range repulsion (d3 manyBody.distanceMax). Beyond this, nodes
        // stop pushing each other — orphans no longer rocket to infinity.
        let distanceMax = max(rest * 4.5, 260)
        let distanceMax2 = distanceMax * distanceMax
        let velocityKeep = min(max(settings.damping, 0.05), 0.99)
        let collideStrength = 0.75 * anim
        let radialBase = 0.012 * anim

        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)

        // ── Many-body: always spatial for n≥120 (O(n²) kills 60fps with big vaults) ──
        if n < 120 {
            for i in 0..<n {
                for j in (i + 1)..<n {
                    applyCharge(i: i, j: j, charge: charge, distanceMax2: distanceMax2, fx: &fx, fy: &fy)
                }
            }
        } else {
            applyChargeGrid(charge: charge, distanceMax2: distanceMax2, fx: &fx, fy: &fy, rest: rest)
        }

        // ── Link springs O(E) ───────────────────────────────────────────────────
        for e in edges {
            let i = e.source
            let j = e.target
            var dx = nodes[j].x - nodes[i].x
            var dy = nodes[j].y - nodes[i].y
            var dist = sqrt(dx * dx + dy * dy)
            if dist < 1e-6 {
                dist = 1e-6
                dx = 1e-6
            }
            let desired = rest / sqrt(max(e.weight, 1))
            let strength = springK * min(max(e.weight, 0.5), 2.5)
            let l = ((dist - desired) / dist) * strength * alpha
            fx[i] += dx * l
            fy[i] += dy * l
            fx[j] -= dx * l
            fy[j] -= dy * l
        }

        // ── Collision: spatial only; skip when nearly cool (huge win for large N) ─
        if alpha > 0.02 {
            if n < 80 {
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        applyCollision(i: i, j: j, strength: collideStrength, fx: &fx, fy: &fy)
                    }
                }
            } else {
                applyCollisionGrid(strength: collideStrength, fx: &fx, fy: &fy, rest: rest)
            }
        }

        // ── Weak radial tether + outer fence ────────────────────────────────────
        let outerR = distanceMax * 0.95
        for i in 0..<n {
            if nodes[i].pinned { continue }
            let k = radialBase * (nodes[i].degree == 0 ? 2.4 : 1.0) * alpha
            fx[i] -= nodes[i].x * k
            fy[i] -= nodes[i].y * k
            let r = hypot(nodes[i].x, nodes[i].y)
            if r > outerR {
                let pull = ((r - outerR) / r) * 0.08
                fx[i] -= nodes[i].x * pull
                fy[i] -= nodes[i].y * pull
            }
        }

        // ── Integrate ───────────────────────────────────────────────────────────
        for i in 0..<n {
            if nodes[i].pinned {
                nodes[i].vx = 0
                nodes[i].vy = 0
                continue
            }
            nodes[i].vx = (nodes[i].vx + fx[i] / nodes[i].mass) * velocityKeep
            nodes[i].vy = (nodes[i].vy + fy[i] / nodes[i].mass) * velocityKeep

            let sp = hypot(nodes[i].vx, nodes[i].vy)
            let maxSp = 24.0
            if sp > maxSp {
                nodes[i].vx = nodes[i].vx / sp * maxSp
                nodes[i].vy = nodes[i].vy / sp * maxSp
            }

            nodes[i].x += nodes[i].vx
            nodes[i].y += nodes[i].vy
        }

        recenter(strength: min(max(settings.centerForce, 0), 1))

        return alpha >= alphaMin || alphaTarget > 0
    }

    /// Full axis-aligned bounds of every node.
    func boundingBox() -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let first = nodes.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for n in nodes {
            minX = min(minX, n.x - n.radius)
            maxX = max(maxX, n.x + n.radius)
            minY = min(minY, n.y - n.radius)
            maxY = max(maxY, n.y + n.radius)
        }
        return (minX, minY, maxX, maxY)
    }

    /// Bounds for camera framing: prefer the connected core, then include nearby isolates.
    /// Prevents a single far orphan from zooming the main graph down to a speck.
    func framingBox() -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard !nodes.isEmpty else { return nil }

        let linked = nodes.filter { $0.degree > 0 }
        let core = linked.isEmpty ? nodes : linked

        var cx = 0.0, cy = 0.0
        for n in core {
            cx += n.x
            cy += n.y
        }
        cx /= Double(core.count)
        cy /= Double(core.count)

        // Core radius = max distance of core nodes from COM.
        var coreR: Double = 40
        for n in core {
            coreR = max(coreR, hypot(n.x - cx, n.y - cy) + n.radius)
        }
        // Allow orphans within ~1.35× of the core cloud (Obsidian periphery).
        let includeR = coreR * 1.35 + max(settings.springLength, 80)

        var minX = cx, maxX = cx, minY = cy, maxY = cy
        var any = false
        for n in nodes {
            let d = hypot(n.x - cx, n.y - cy)
            if n.degree > 0 || d <= includeR {
                any = true
                minX = min(minX, n.x - n.radius)
                maxX = max(maxX, n.x + n.radius)
                minY = min(minY, n.y - n.radius)
                maxY = max(maxY, n.y + n.radius)
            }
        }
        if !any { return boundingBox() }
        // Minimum span so a 2-node graph still has room.
        if maxX - minX < 80 {
            let m = (minX + maxX) / 2
            minX = m - 40
            maxX = m + 40
        }
        if maxY - minY < 80 {
            let m = (minY + maxY) / 2
            minY = m - 40
            maxY = m + 40
        }
        return (minX, minY, maxX, maxY)
    }

    func positions() -> [String: SIMD2<Double>] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, SIMD2($0.x, $0.y)) })
    }

    // MARK: - Private forces

    private func applyCharge(
        i: Int,
        j: Int,
        charge: Double,
        distanceMax2: Double,
        fx: inout [Double],
        fy: inout [Double]
    ) {
        var dx = nodes[j].x - nodes[i].x
        var dy = nodes[j].y - nodes[i].y
        var dist2 = dx * dx + dy * dy
        if dist2 > distanceMax2 { return }
        if dist2 < 1 {
            if dist2 < 1e-6 {
                dx = Double.random(in: -1...1)
                dy = Double.random(in: -1...1)
                dist2 = dx * dx + dy * dy
            }
            dist2 = max(dist2, 1)
        }
        let w = (charge * alpha) / dist2
        fx[i] += dx * w
        fy[i] += dy * w
        fx[j] -= dx * w
        fy[j] -= dy * w
    }

    private func applyChargeGrid(
        charge: Double,
        distanceMax2: Double,
        fx: inout [Double],
        fy: inout [Double],
        rest: Double
    ) {
        let n = nodes.count
        let cellSize = max(rest * 2.5, 50)
        var grid: [Int64: [Int]] = [:]
        grid.reserveCapacity(n)
        func key(_ x: Double, _ y: Double) -> Int64 {
            let ix = Int64((x / cellSize).rounded(.down))
            let iy = Int64((y / cellSize).rounded(.down))
            return (ix << 32) ^ (iy & 0xffffffff)
        }
        for i in 0..<n {
            grid[key(nodes[i].x, nodes[i].y), default: []].append(i)
        }
        for i in 0..<n {
            let ix = Int((nodes[i].x / cellSize).rounded(.down))
            let iy = Int((nodes[i].y / cellSize).rounded(.down))
            for ox in -2...2 {
                for oy in -2...2 {
                    let k = (Int64(ix + ox) << 32) ^ (Int64(iy + oy) & 0xffffffff)
                    guard let bucket = grid[k] else { continue }
                    for j in bucket where j > i {
                        applyCharge(i: i, j: j, charge: charge, distanceMax2: distanceMax2, fx: &fx, fy: &fy)
                    }
                }
            }
        }
    }

    private func applyCollision(i: Int, j: Int, strength: Double, fx: inout [Double], fy: inout [Double]) {
        var dx = nodes[j].x - nodes[i].x
        var dy = nodes[j].y - nodes[i].y
        var dist = sqrt(dx * dx + dy * dy)
        let minDist = nodes[i].radius + nodes[j].radius + 6
        if dist >= minDist { return }
        if dist < 1e-6 {
            dist = 1e-6
            dx = 1e-6
            dy = 0
        }
        let overlap = (minDist - dist) / dist * strength * alpha
        let fxv = dx * overlap
        let fyv = dy * overlap
        let mi = nodes[i].mass
        let mj = nodes[j].mass
        let total = mi + mj
        fx[i] -= fxv * (mj / total)
        fy[i] -= fyv * (mj / total)
        fx[j] += fxv * (mi / total)
        fy[j] += fyv * (mi / total)
    }

    /// Near-neighbor collision via spatial hash (O(n) avg) — required for large vaults.
    private func applyCollisionGrid(strength: Double, fx: inout [Double], fy: inout [Double], rest: Double) {
        let n = nodes.count
        let cellSize = max(rest * 0.55, 24)
        var grid: [Int64: [Int]] = [:]
        grid.reserveCapacity(n)
        func key(_ x: Double, _ y: Double) -> Int64 {
            let ix = Int64((x / cellSize).rounded(.down))
            let iy = Int64((y / cellSize).rounded(.down))
            return (ix << 32) ^ (iy & 0xffffffff)
        }
        for i in 0..<n {
            grid[key(nodes[i].x, nodes[i].y), default: []].append(i)
        }
        for i in 0..<n {
            let ix = Int((nodes[i].x / cellSize).rounded(.down))
            let iy = Int((nodes[i].y / cellSize).rounded(.down))
            for ox in -1...1 {
                for oy in -1...1 {
                    let k = (Int64(ix + ox) << 32) ^ (Int64(iy + oy) & 0xffffffff)
                    guard let bucket = grid[k] else { continue }
                    for j in bucket where j > i {
                        applyCollision(i: i, j: j, strength: strength, fx: &fx, fy: &fy)
                    }
                }
            }
        }
    }

    private func recenter(strength: Double) {
        guard strength > 0, !nodes.isEmpty else { return }
        if nodes.contains(where: \.pinned) { return }

        var cx = 0.0, cy = 0.0
        for node in nodes {
            cx += node.x
            cy += node.y
        }
        cx /= Double(nodes.count)
        cy /= Double(nodes.count)
        let k = min(max(strength, 0), 1)
        if abs(cx) < 1e-9, abs(cy) < 1e-9 { return }
        for i in nodes.indices {
            nodes[i].x -= cx * k
            nodes[i].y -= cy * k
        }
    }
}
