import Foundation

/// Offline-safe math helpers for ObjectForge single-photo reconstruction.
///
/// These helpers are deliberately small and dependency-free so they run inside
/// the iPhone build without OpenCV. They provide the Swift equivalents of the
/// old Python Math3D notes: chroma masking, solid island cleanup, distance puff
/// depth, and anti-ridge smoothing.
enum ObjectForgeMaskPuffMath {
    /// Build a saturation/chroma mask from RGB samples. Shadows tend to be low
    /// chroma; real subject color usually stays higher.
    static func saturationMask(red: [Float], green: [Float], blue: [Float], threshold: Float = 0.14) -> [Float] {
        let count = min(red.count, min(green.count, blue.count))
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let r = clamp01(red[i])
            let g = clamp01(green[i])
            let b = clamp01(blue[i])
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let sat = maxC <= 0.0001 ? 0 : (maxC - minC) / maxC
            out[i] = smoothStep(edge0: threshold * 0.55, edge1: threshold * 1.72, x: sat)
        }
        return out
    }

    /// Strong close/fill pass for the current "solid subject but holes remain"
    /// problem. This intentionally fills interior cavities and bridges one-cell
    /// cracks while still rejecting border-connected background so the old square
    /// slab failure does not come back.
    static func closeInteriorHoles(_ mask: [Float], grid: Int, iterations: Int = 4) -> [Float] {
        guard grid > 2, mask.count == grid * grid else { return mask }
        var binary = mask.map { $0 > 0.38 }
        let passes = max(3, iterations + 2)

        // Morphological close: grow subject into tiny cracks, then lightly prune.
        for _ in 0..<passes {
            binary = growIntoSmallGaps(binary, grid: grid, neighborNeeded: 3)
        }
        binary = fillEnclosedHoles(binary, grid: grid)
        binary = keepLargestCenteredIsland(binary, grid: grid)
        for _ in 0..<2 {
            binary = pruneTinySpikes(binary, grid: grid, neighborNeeded: 2)
        }
        binary = fillEnclosedHoles(binary, grid: grid)
        binary = keepLargestCenteredIsland(binary, grid: grid)

        // Return a soft mask: solid interior gets 1.0, immediate border gets
        // a shoulder so later 0.50 cell tests do not punch random holes.
        var out = binary.map { $0 ? Float(1) : Float(0) }
        out = gaussian3x3(out, grid: grid)
        return out.map { value in
            if value >= 0.30 { return min(1, max(0.72, value)) }
            return 0
        }
    }

    /// Keep the main subject island and discard speckles/background islands.
    static func keepLargestCenteredIsland(_ input: [Bool], grid: Int) -> [Bool] {
        guard input.count == grid * grid, grid > 1 else { return input }
        var visited = [Bool](repeating: false, count: input.count)
        var best: [Int] = []
        var bestScore: Float = -1
        let center = Float(grid - 1) / 2

        for start in input.indices where input[start] && !visited[start] {
            var stack = [start]
            var component: [Int] = []
            var touchesFrame = false
            var centerScore: Float = 0
            visited[start] = true

            while let idx = stack.popLast() {
                component.append(idx)
                let x = idx % grid
                let y = idx / grid
                if x == 0 || y == 0 || x == grid - 1 || y == grid - 1 { touchesFrame = true }
                let dx = abs(Float(x) - center) / max(center, 1)
                let dy = abs(Float(y) - center) / max(center, 1)
                centerScore += max(0, 1 - (dx + dy) * 0.5)
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] {
                    guard nx >= 0, ny >= 0, nx < grid, ny < grid else { continue }
                    let ni = ny * grid + nx
                    if input[ni] && !visited[ni] {
                        visited[ni] = true
                        stack.append(ni)
                    }
                }
            }

            let framePenalty: Float = touchesFrame ? 0.12 : 1.0
            let score = (Float(component.count) + centerScore * 0.30) * framePenalty
            if score > bestScore {
                bestScore = score
                best = component
            }
        }

        if best.count < 8 { return input }
        var out = [Bool](repeating: false, count: input.count)
        for idx in best { out[idx] = true }
        return out
    }

    /// Approximate distance-transform puff depth. A cell near the silhouette is
    /// shallow; interior cells rise smoothly toward the center.
    static func distancePuff(mask: [Float], grid: Int) -> [Float] {
        guard grid > 1, mask.count == grid * grid else { return mask }
        let inf = grid * grid
        var dist = [Int](repeating: inf, count: mask.count)
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = y * grid + x
                if mask[idx] <= 0.45 { dist[idx] = 0 }
            }
        }
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = y * grid + x
                if x > 0 { dist[idx] = min(dist[idx], dist[y * grid + x - 1] + 1) }
                if y > 0 { dist[idx] = min(dist[idx], dist[(y - 1) * grid + x] + 1) }
            }
        }
        for y in stride(from: grid - 1, through: 0, by: -1) {
            for x in stride(from: grid - 1, through: 0, by: -1) {
                let idx = y * grid + x
                if x < grid - 1 { dist[idx] = min(dist[idx], dist[y * grid + x + 1] + 1) }
                if y < grid - 1 { dist[idx] = min(dist[idx], dist[(y + 1) * grid + x] + 1) }
            }
        }
        let maxDist = max(1, dist.filter { $0 < inf }.max() ?? 1)
        var out = [Float](repeating: 0, count: mask.count)
        for i in mask.indices {
            guard mask[i] > 0.45 else { continue }
            let normalized = Float(dist[i]) / Float(maxDist)
            out[i] = smoothStep(edge0: 0.0, edge1: 1.0, x: normalized)
        }
        return gaussian3x3(gaussian3x3(out, grid: grid), grid: grid)
    }

    /// Tiny Gaussian-style blur to remove stair-step ridges without destroying silhouette.
    static func gaussian3x3(_ values: [Float], grid: Int) -> [Float] {
        guard values.count == grid * grid, grid > 2 else { return values }
        let weights: [[Float]] = [[1, 2, 1], [2, 4, 2], [1, 2, 1]]
        var out = values
        for y in 1..<(grid - 1) {
            for x in 1..<(grid - 1) {
                var sum: Float = 0
                var wsum: Float = 0
                for yy in -1...1 {
                    for xx in -1...1 {
                        let weight = weights[yy + 1][xx + 1]
                        sum += values[(y + yy) * grid + (x + xx)] * weight
                        wsum += weight
                    }
                }
                out[y * grid + x] = sum / max(wsum, 0.0001)
            }
        }
        return out
    }

    private static func growIntoSmallGaps(_ input: [Bool], grid: Int, neighborNeeded: Int) -> [Bool] {
        var out = input
        for y in 1..<(grid - 1) {
            for x in 1..<(grid - 1) where !input[y * grid + x] {
                let count = neighborCount(input, grid: grid, x: x, y: y)
                if count >= neighborNeeded { out[y * grid + x] = true }
            }
        }
        return out
    }

    private static func pruneTinySpikes(_ input: [Bool], grid: Int, neighborNeeded: Int) -> [Bool] {
        var out = input
        for y in 1..<(grid - 1) {
            for x in 1..<(grid - 1) where input[y * grid + x] {
                let count = neighborCount(input, grid: grid, x: x, y: y)
                if count < neighborNeeded { out[y * grid + x] = false }
            }
        }
        return out
    }

    private static func fillEnclosedHoles(_ input: [Bool], grid: Int) -> [Bool] {
        guard input.count == grid * grid else { return input }
        var outside = [Bool](repeating: false, count: input.count)
        var stack: [Int] = []
        func push(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < grid, y < grid else { return }
            let idx = y * grid + x
            if !input[idx] && !outside[idx] {
                outside[idx] = true
                stack.append(idx)
            }
        }
        for i in 0..<grid {
            push(i, 0); push(i, grid - 1); push(0, i); push(grid - 1, i)
        }
        while let idx = stack.popLast() {
            let x = idx % grid
            let y = idx / grid
            push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1)
        }
        var out = input
        for i in out.indices where !out[i] && !outside[i] { out[i] = true }
        return out
    }

    private static func neighborCount(_ values: [Bool], grid: Int, x: Int, y: Int) -> Int {
        var count = 0
        for yy in max(0, y - 1)...min(grid - 1, y + 1) {
            for xx in max(0, x - 1)...min(grid - 1, x + 1) where !(xx == x && yy == y) {
                if values[yy * grid + xx] { count += 1 }
            }
        }
        return count
    }

    private static func smoothStep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = clamp01((x - edge0) / max(edge1 - edge0, 0.0001))
        return t * t * (3 - 2 * t)
    }

    private static func clamp01(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
