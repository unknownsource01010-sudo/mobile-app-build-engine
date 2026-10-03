import SwiftUI
import SceneKit
import UIKit
import Vision
import CoreImage

struct DimensionEditPanel: View {
    @Binding var widthMM: Double
    @Binding var heightMM: Double
    @Binding var depthMM: Double
    @Binding var uniformScale: Bool
    var onApply: () -> Void
    var onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Uniform scale lock", isOn: $uniformScale).font(.headline)
            dimensionRow(label: "Length / Width", value: $widthMM, range: 10...300)
            dimensionRow(label: "Height", value: $heightMM, range: 10...300)
            dimensionRow(label: "Depth / Relief", value: $depthMM, range: 1...80)
            HStack {
                Button("Apply Size", action: onApply).buttonStyle(.borderedProminent)
                Button("Reset", action: onReset).buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onChange(of: widthMM) { oldValue, newValue in
            if uniformScale {
                let ratio = max(newValue / max(oldValue, 0.01), 0.01)
                heightMM = max(10, min(300, heightMM * ratio))
            }
        }
    }

    private func dimensionRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(value.wrappedValue)) mm")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("-") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) }.buttonStyle(.bordered)
                Slider(value: value, in: range)
                Button("+") { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) }.buttonStyle(.bordered)
            }
        }
    }
}

struct FrontLogicSettings: Equatable {
    var gridSize: Int = 76
    var reliefStrength: Float = 12
    var baseThickness: Float = 3
    var smoothingPasses: Int = 2
    var invertDepth: Bool = false
    var edgeBoost: Float = 0.65
    var removeBackground: Bool = true
    var backgroundThreshold: Float = 0.16
    var subjectRaised: Bool = true
    var subjectCutout: Bool = true
    var darkDetailRaised: Bool = true
    var shadowReduction: Float = 0.72
    var contourWeight: Float = 0.70
    var useVisionForegroundMask: Bool = true

    mutating func clamp() {
        gridSize = max(16, min(140, gridSize))
        reliefStrength = max(0.5, min(80, reliefStrength))
        baseThickness = max(0.5, min(25, baseThickness))
        smoothingPasses = max(0, min(8, smoothingPasses))
        edgeBoost = max(0, min(2, edgeBoost))
        backgroundThreshold = max(0.03, min(0.45, backgroundThreshold))
        shadowReduction = max(0, min(1, shadowReduction))
        contourWeight = max(0, min(1.5, contourWeight))
    }
}

final class ReliefMeshBuilder {
    func buildRelief(from image: UIImage, settings rawSettings: FrontLogicSettings) throws -> MeshModel {
        var settings = rawSettings
        settings.clamp()
        guard let cgImage = image.cgImage else { throw FrontLogicError.invalidImage }
        let grid = settings.gridSize
        let samples = try samplePixels(cgImage: cgImage, grid: grid)
        let luminance = samples.map { $0.l }

        var mask = [Float](repeating: 1, count: grid * grid)
        if settings.removeBackground {
            let heuristicMask = makeForegroundMask(samples: samples, grid: grid, threshold: settings.backgroundThreshold)
            let otsuMask = makeOtsuForegroundMask(samples: samples, grid: grid)
            let visionMask: [Float]?
            if settings.useVisionForegroundMask, #available(iOS 17.0, *) {
                visionMask = makeVisionForegroundMask(cgImage: cgImage, grid: grid)
            } else {
                visionMask = nil
            }
            mask = strictForegroundMask(vision: visionMask, heuristic: heuristicMask, otsu: otsuMask, grid: grid)
        }

        var heights = makeShapeAwareHeightMap(luminance: luminance, mask: mask, grid: grid, settings: settings)
        for _ in 0..<settings.smoothingPasses { heights = smooth(heights, grid: grid, mask: mask) }
        if settings.subjectCutout && settings.removeBackground {
            let cutout = makeSubjectCutoutMesh(heights: heights, mask: mask, samples: samples, grid: grid, imageSize: image.size)
            if !cutout.isEmpty { return cutout }
        }
        return makeFlatBackMesh(heights: heights, mask: mask, samples: samples, grid: grid, imageSize: image.size)
    }

    @available(iOS 17.0, *)
    private func makeVisionForegroundMask(cgImage: CGImage, grid: Int) -> [Float]? {
        do {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let pixelBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return gridMask(from: pixelBuffer, grid: grid)
        } catch {
            return nil
        }
    }

    private func gridMask(from pixelBuffer: CVPixelBuffer, grid: Int) -> [Float]? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgMask = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return sampleMaskPixels(cgImage: cgMask, grid: grid)
    }

    private func sampleMaskPixels(cgImage: CGImage, grid: Int) -> [Float]? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: grid * grid * 4)
        guard let bitmap = CGContext(data: &bytes,
                                     width: grid,
                                     height: grid,
                                     bitsPerComponent: 8,
                                     bytesPerRow: grid * 4,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        var mask: [Float] = []
        mask.reserveCapacity(grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let i = (y * grid + x) * 4
                let r = Float(bytes[i]) / 255
                let g = Float(bytes[i + 1]) / 255
                let b = Float(bytes[i + 2]) / 255
                let a = Float(bytes[i + 3]) / 255
                mask.append(max(a, max(r, max(g, b))))
            }
        }
        return cleanVisionMask(mask, grid: grid)
    }

    private func strictForegroundMask(vision: [Float]?, heuristic: [Float], otsu: [Float], grid: Int) -> [Float] {
        let chosen: [Float]
        if let vision, usefulCoverage(vision) {
            // Vision wins. The heuristic may only add very strong interior pixels, never flood the frame.
            chosen = zip(vision, heuristic).map { max($0.0, $0.1 > 0.88 ? min($0.1, 0.55) : 0) }
        } else if usefulCoverage(heuristic) {
            chosen = heuristic
        } else {
            chosen = otsu
        }

        var binary = chosen.map { $0 >= 0.46 }
        if foregroundCoverage(binary) > 0.62 {
            binary = otsu.map { $0 >= 0.50 }
        }
        if foregroundCoverage(binary) > 0.62 {
            // A near-full mask is the old square-slab failure mode. Punch out the frame and keep only the centered object island.
            for y in 0..<grid {
                for x in 0..<grid where x < 3 || y < 3 || x >= grid - 3 || y >= grid - 3 {
                    binary[y * grid + x] = false
                }
            }
        }

        binary = closeBinaryHoles(binary, grid: grid)
        binary = keepBestSubjectIsland(binary, grid: grid)
        var out = binary.map { $0 ? Float(1) : Float(0) }
        out = softenBinaryMask(out, grid: grid)
        return out.map { $0 < 0.42 ? 0 : min(1, $0) }
    }

    private func usefulCoverage(_ mask: [Float]) -> Bool {
        let coverage = mask.reduce(Float(0)) { $0 + ($1 > 0.42 ? 1 : 0) } / Float(max(mask.count, 1))
        return coverage > 0.015 && coverage < 0.72
    }

    private func foregroundCoverage(_ mask: [Bool]) -> Float {
        Float(mask.filter { $0 }.count) / Float(max(mask.count, 1))
    }

    private func cleanVisionMask(_ values: [Float], grid: Int) -> [Float] {
        var out = values.map { $0 < 0.16 ? 0 : min(1, $0) }
        out = closeSmallMaskHoles(out, grid: grid)
        out = smoothMask(out, grid: grid)
        return out.map { $0 < 0.28 ? 0 : min(1, $0) }
    }

    private func closeSmallMaskHoles(_ values: [Float], grid: Int) -> [Float] {
        var out = values
        for y in 1..<(grid - 1) {
            for x in 1..<(grid - 1) {
                let idx = y * grid + x
                let n = [values[(y - 1) * grid + x], values[(y + 1) * grid + x], values[y * grid + x - 1], values[y * grid + x + 1]]
                let strongNeighbors = n.filter { $0 > 0.65 }.count
                if values[idx] < 0.20 && strongNeighbors >= 3 { out[idx] = 0.70 }
            }
        }
        return out
    }

    private func makeOtsuForegroundMask(samples: [PixelSample], grid: Int) -> [Float] {
        let luminance = samples.map { max(0, min(1, $0.l)) }
        var hist = [Int](repeating: 0, count: 256)
        for l in luminance { hist[max(0, min(255, Int(l * 255)))] += 1 }
        let total = luminance.count
        var sumAll = 0
        for i in 0..<256 { sumAll += i * hist[i] }
        var sumB = 0
        var weightB = 0
        var bestVariance: Double = -1
        var threshold = 127
        for i in 0..<256 {
            weightB += hist[i]
            if weightB == 0 { continue }
            let weightF = total - weightB
            if weightF == 0 { break }
            sumB += i * hist[i]
            let meanB = Double(sumB) / Double(weightB)
            let meanF = Double(sumAll - sumB) / Double(weightF)
            let variance = Double(weightB) * Double(weightF) * pow(meanB - meanF, 2)
            if variance > bestVariance {
                bestVariance = variance
                threshold = i
            }
        }
        let borderAverage = averageBorderLuminance(samples: samples, grid: grid)
        let centerAverage = averageCenterLuminance(samples: samples, grid: grid)
        let subjectIsDarker = centerAverage < borderAverage
        return luminance.map { l in
            let v = Int(l * 255)
            let hit = subjectIsDarker ? (v < threshold) : (v > threshold)
            return hit ? Float(1) : Float(0)
        }
    }

    private func averageBorderLuminance(samples: [PixelSample], grid: Int) -> Float {
        var sum: Float = 0, count: Float = 0
        for y in 0..<grid {
            for x in 0..<grid where x < 2 || y < 2 || x >= grid - 2 || y >= grid - 2 {
                sum += samples[y * grid + x].l; count += 1
            }
        }
        return sum / max(count, 1)
    }

    private func averageCenterLuminance(samples: [PixelSample], grid: Int) -> Float {
        let lo = grid / 3, hi = (grid * 2) / 3
        var sum: Float = 0, count: Float = 0
        for y in lo..<hi { for x in lo..<hi { sum += samples[y * grid + x].l; count += 1 } }
        return sum / max(count, 1)
    }

    private func closeBinaryHoles(_ input: [Bool], grid: Int) -> [Bool] {
        var out = input
        for y in 1..<(grid - 1) {
            for x in 1..<(grid - 1) where !input[y * grid + x] {
                var neighbors = 0
                for yy in (y - 1)...(y + 1) {
                    for xx in (x - 1)...(x + 1) where !(xx == x && yy == y) {
                        if input[yy * grid + xx] { neighbors += 1 }
                    }
                }
                if neighbors >= 6 { out[y * grid + x] = true }
            }
        }
        return out
    }

    private func keepBestSubjectIsland(_ input: [Bool], grid: Int) -> [Bool] {
        var visited = [Bool](repeating: false, count: input.count)
        var best: [Int] = []
        var bestScore: Float = -1
        let center = Float(grid - 1) / 2
        for i in input.indices where input[i] && !visited[i] {
            var stack = [i]
            var comp: [Int] = []
            visited[i] = true
            var touchesBorder = false
            var centerBonus: Float = 0
            while let idx = stack.popLast() {
                comp.append(idx)
                let x = idx % grid, y = idx / grid
                if x == 0 || y == 0 || x == grid - 1 || y == grid - 1 { touchesBorder = true }
                let dx = abs(Float(x) - center) / max(center, 1)
                let dy = abs(Float(y) - center) / max(center, 1)
                centerBonus += max(0, 1 - (dx + dy) / 2)
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] {
                    guard nx >= 0, ny >= 0, nx < grid, ny < grid else { continue }
                    let ni = ny * grid + nx
                    if input[ni] && !visited[ni] {
                        visited[ni] = true
                        stack.append(ni)
                    }
                }
            }
            let borderPenalty: Float = touchesBorder ? 0.18 : 1.0
            let score = (Float(comp.count) + centerBonus * 0.22) * borderPenalty
            if score > bestScore {
                bestScore = score
                best = comp
            }
        }
        if best.count < 8 { return input }
        var out = [Bool](repeating: false, count: input.count)
        for idx in best { out[idx] = true }
        return out
    }

    private func softenBinaryMask(_ input: [Float], grid: Int) -> [Float] {
        var out = input
        for y in 0..<grid {
            for x in 0..<grid {
                var sum: Float = 0, count: Float = 0
                for yy in max(0, y - 1)...min(grid - 1, y + 1) {
                    for xx in max(0, x - 1)...min(grid - 1, x + 1) {
                        sum += input[yy * grid + xx]; count += 1
                    }
                }
                let avg = sum / max(count, 1)
                out[y * grid + x] = input[y * grid + x] > 0 ? max(0.72, avg) : (avg > 0.74 ? 0.55 : 0)
            }
        }
        return out
    }

    private func samplePixels(cgImage: CGImage, grid: Int) throws -> [PixelSample] {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: grid * grid * 4)
        guard let bitmap = CGContext(data: &bytes,
                                     width: grid,
                                     height: grid,
                                     bitsPerComponent: 8,
                                     bytesPerRow: grid * 4,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FrontLogicError.bitmapFailed
        }
        bitmap.interpolationQuality = .high
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        var out: [PixelSample] = []
        out.reserveCapacity(grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let i = (y * grid + x) * 4
                let r = Float(bytes[i]) / 255
                let g = Float(bytes[i + 1]) / 255
                let b = Float(bytes[i + 2]) / 255
                let a = Float(bytes[i + 3]) / 255
                let l = (0.2126 * r + 0.7152 * g + 0.0722 * b) * a
                out.append(PixelSample(r: r, g: g, b: b, a: a, l: l))
            }
        }
        return out
    }

    private func makeForegroundMask(samples: [PixelSample], grid: Int, threshold: Float) -> [Float] {
        let luminance = samples.map { $0.l }
        var br: Float = 0, bg: Float = 0, bb: Float = 0, bl: Float = 0, count: Float = 0
        for y in 0..<grid {
            for x in 0..<grid where x == 0 || y == 0 || x == grid - 1 || y == grid - 1 {
                let p = samples[y * grid + x]
                br += p.r; bg += p.g; bb += p.b; bl += p.l; count += 1
            }
        }
        br /= max(count, 1); bg /= max(count, 1); bb /= max(count, 1); bl /= max(count, 1)

        var raw = [Float](repeating: 0, count: grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = y * grid + x
                let p = samples[idx]
                let colorDistance = sqrt((p.r - br) * (p.r - br) + (p.g - bg) * (p.g - bg) + (p.b - bb) * (p.b - bb))
                let lumDistance = abs(p.l - bl)
                let edge = localEdge(luminance, grid: grid, x: x, y: y)
                let centerBias = centerWeight(x: x, y: y, grid: grid) * 0.12
                let score = colorDistance * 0.62 + lumDistance * 0.28 + edge * 0.52 + centerBias
                raw[idx] = smoothStep(edge0: threshold * 0.82, edge1: threshold * 2.05, x: score)
            }
        }
        var smoothed = raw
        for _ in 0..<1 { smoothed = smoothMask(smoothed, grid: grid) }
        return smoothed.map { $0 < 0.32 ? 0 : min(1, $0) }
    }

    private func centerWeight(x: Int, y: Int, grid: Int) -> Float {
        let fx = (Float(x) / Float(max(grid - 1, 1))) - 0.5
        let fy = (Float(y) / Float(max(grid - 1, 1))) - 0.5
        let dist = sqrt(fx * fx + fy * fy)
        return max(0, 1 - dist * 2.2)
    }

    private func smoothStep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / max(edge1 - edge0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    private func makeShapeAwareHeightMap(luminance: [Float], mask: [Float], grid: Int, settings: FrontLogicSettings) -> [Float] {
        var lighting = luminance
        for _ in 0..<5 { lighting = smoothMask(lighting, grid: grid) }
        var heights = [Float](repeating: settings.baseThickness, count: grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = y * grid + x
                let subject = max(0, min(1, mask[idx]))
                let l = luminance[idx]
                let softLight = lighting[idx]
                let edge = localEdge(luminance, grid: grid, x: x, y: y)
                let localContrast = min(1, abs(l - softLight) * 3.0)
                let darkFeature = settings.darkDetailRaised ? max(0, softLight - l) * 0.75 : 0
                let brightnessDepth = settings.invertDepth ? (1 - l) : l
                let shadowReducedDepth = brightnessDepth * (1 - settings.shadowReduction)
                let subjectLift: Float = settings.subjectRaised ? 0.24 : 0
                let contour = edge * settings.edgeBoost * settings.contourWeight
                let detail = max(0, min(1, subjectLift + contour + localContrast * 0.58 + darkFeature + shadowReducedDepth * 0.28))
                heights[idx] = settings.baseThickness + (detail * settings.reliefStrength * subject)
            }
        }
        return heights
    }

    private func localEdge(_ values: [Float], grid: Int, x: Int, y: Int) -> Float {
        let center = values[y * grid + x]
        let left = values[y * grid + max(0, x - 1)]
        let right = values[y * grid + min(grid - 1, x + 1)]
        let up = values[max(0, y - 1) * grid + x]
        let down = values[min(grid - 1, y + 1) * grid + x]
        return min(1, abs(center - (left + right + up + down) / 4) + abs(right - left) + abs(down - up))
    }

    private func smooth(_ values: [Float], grid: Int, mask: [Float]) -> [Float] {
        var out = values
        for y in 0..<grid {
            for x in 0..<grid {
                var sum: Float = 0
                var weightSum: Float = 0
                for yy in max(0, y - 1)...min(grid - 1, y + 1) {
                    for xx in max(0, x - 1)...min(grid - 1, x + 1) {
                        let idx = yy * grid + xx
                        let w = max(0.15, mask[idx])
                        sum += values[idx] * w
                        weightSum += w
                    }
                }
                out[y * grid + x] = sum / max(weightSum, 0.0001)
            }
        }
        return out
    }

    private func smoothMask(_ values: [Float], grid: Int) -> [Float] {
        var out = values
        for y in 0..<grid {
            for x in 0..<grid {
                var sum: Float = 0
                var count: Float = 0
                for yy in max(0, y - 1)...min(grid - 1, y + 1) {
                    for xx in max(0, x - 1)...min(grid - 1, x + 1) {
                        sum += values[yy * grid + xx]
                        count += 1
                    }
                }
                out[y * grid + x] = sum / max(count, 1)
            }
        }
        return out
    }

    private func makeFlatBackMesh(heights: [Float], mask: [Float], samples: [PixelSample], grid: Int, imageSize: CGSize) -> MeshModel {
        var vertices: [Vertex3D] = []
        var triangles: [Triangle3D] = []
        for y in 0..<grid {
            for x in 0..<grid {
                let s = samples[y * grid + x]
                vertices.append(Vertex3D(x: Float(x) / Float(grid - 1) - 0.5,
                                         y: 0.5 - Float(y) / Float(grid - 1),
                                         z: heights[y * grid + x],
                                         r: s.r, g: s.g, b: s.b))
            }
        }
        let bottomOffset = vertices.count
        for y in 0..<grid {
            for x in 0..<grid {
                let s = samples[y * grid + x]
                vertices.append(Vertex3D(x: Float(x) / Float(grid - 1) - 0.5,
                                         y: 0.5 - Float(y) / Float(grid - 1),
                                         z: 0,
                                         r: s.r, g: s.g, b: s.b))
            }
        }
        func top(_ x: Int, _ y: Int) -> Int { y * grid + x }
        func bottom(_ x: Int, _ y: Int) -> Int { bottomOffset + y * grid + x }
        for y in 0..<(grid - 1) {
            for x in 0..<(grid - 1) {
                let a = top(x, y), b = top(x + 1, y), c = top(x, y + 1), d = top(x + 1, y + 1)
                triangles.append(Triangle3D(a: a, b: c, c: b))
                triangles.append(Triangle3D(a: b, b: c, c: d))
                let ba = bottom(x, y), bb = bottom(x + 1, y), bc = bottom(x, y + 1), bd = bottom(x + 1, y + 1)
                triangles.append(Triangle3D(a: ba, b: bb, c: bc))
                triangles.append(Triangle3D(a: bb, b: bd, c: bc))
            }
        }
        for x in 0..<(grid - 1) {
            addWall(topA: top(x, 0), topB: top(x + 1, 0), bottomA: bottom(x, 0), bottomB: bottom(x + 1, 0), triangles: &triangles)
            addWall(topA: top(x + 1, grid - 1), topB: top(x, grid - 1), bottomA: bottom(x + 1, grid - 1), bottomB: bottom(x, grid - 1), triangles: &triangles)
        }
        for y in 0..<(grid - 1) {
            addWall(topA: top(0, y + 1), topB: top(0, y), bottomA: bottom(0, y + 1), bottomB: bottom(0, y), triangles: &triangles)
            addWall(topA: top(grid - 1, y), topB: top(grid - 1, y + 1), bottomA: bottom(grid - 1, y), bottomB: bottom(grid - 1, y + 1), triangles: &triangles)
        }
        return MeshModel(vertices: vertices, triangles: triangles, sourceImageSize: imageSize)
    }

    private func makeSubjectCutoutMesh(heights: [Float], mask: [Float], samples: [PixelSample], grid: Int, imageSize: CGSize) -> MeshModel {
        var vertices: [Vertex3D] = []
        var triangles: [Triangle3D] = []
        var vertexIndexGrid = [Int](repeating: -1, count: grid * grid)
        var bottomIndexGrid = [Int](repeating: -1, count: grid * grid)
        let threshold: Float = 0.50

        func vertexSolid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < grid, y < grid else { return false }
            return mask[y * grid + x] >= threshold
        }
        func cellSolid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < grid - 1, y < grid - 1 else { return false }
            let a = mask[y * grid + x]
            let b = mask[y * grid + x + 1]
            let c = mask[(y + 1) * grid + x]
            let d = mask[(y + 1) * grid + x + 1]
            return a >= threshold && b >= threshold && c >= threshold && d >= threshold
        }
        func point(_ x: Int, _ y: Int, _ z: Float) -> Vertex3D {
            let s = samples[y * grid + x]
            return Vertex3D(x: Float(x) / Float(grid - 1) - 0.5,
                            y: 0.5 - Float(y) / Float(grid - 1),
                            z: z,
                            r: s.r, g: s.g, b: s.b)
        }
        func top(_ x: Int, _ y: Int) -> Int {
            let idx = y * grid + x
            if vertexIndexGrid[idx] >= 0 { return vertexIndexGrid[idx] }
            let index = vertices.count
            vertices.append(point(x, y, heights[idx]))
            vertexIndexGrid[idx] = index
            return index
        }
        func bottom(_ x: Int, _ y: Int) -> Int {
            let idx = y * grid + x
            if bottomIndexGrid[idx] >= 0 { return bottomIndexGrid[idx] }
            let index = vertices.count
            vertices.append(point(x, y, 0))
            bottomIndexGrid[idx] = index
            return index
        }

        var solidCells = 0
        for y in 0..<(grid - 1) {
            for x in 0..<(grid - 1) where cellSolid(x, y) {
                solidCells += 1
                let a = top(x, y), b = top(x + 1, y), c = top(x, y + 1), d = top(x + 1, y + 1)
                triangles.append(Triangle3D(a: a, b: c, c: b))
                triangles.append(Triangle3D(a: b, b: c, c: d))
                let ba = bottom(x, y), bb = bottom(x + 1, y), bc = bottom(x, y + 1), bd = bottom(x + 1, y + 1)
                triangles.append(Triangle3D(a: ba, b: bb, c: bc))
                triangles.append(Triangle3D(a: bb, b: bd, c: bc))
                if !cellSolid(x, y - 1) { addWall(topA: a, topB: b, bottomA: ba, bottomB: bb, triangles: &triangles) }
                if !cellSolid(x, y + 1) { addWall(topA: d, topB: c, bottomA: bd, bottomB: bc, triangles: &triangles) }
                if !cellSolid(x - 1, y) { addWall(topA: c, topB: a, bottomA: bc, bottomB: ba, triangles: &triangles) }
                if !cellSolid(x + 1, y) { addWall(topA: b, topB: d, bottomA: bb, bottomB: bd, triangles: &triangles) }
            }
        }
        if solidCells < 12 || solidCells > Int(Double((grid - 1) * (grid - 1)) * 0.70) { return .empty }
        return MeshModel(vertices: vertices, triangles: triangles, sourceImageSize: imageSize)
    }

    private func addWall(topA: Int, topB: Int, bottomA: Int, bottomB: Int, triangles: inout [Triangle3D]) {
        triangles.append(Triangle3D(a: topA, b: bottomA, c: topB))
        triangles.append(Triangle3D(a: topB, b: bottomA, c: bottomB))
    }
}

private struct PixelSample {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
    var l: Float
}

enum FrontLogicError: LocalizedError {
    case invalidImage, bitmapFailed
    var errorDescription: String? {
        self == .invalidImage ? "Could not read selected image." : "Could not create image sampler."
    }
}

struct Vertex3D: Hashable {
    var x: Float
    var y: Float
    var z: Float
    var r: Float = 0.0
    var g: Float = 0.85
    var b: Float = 1.0
}
struct Triangle3D: Hashable { var a: Int; var b: Int; var c: Int }

struct MeshModel {
    var vertices: [Vertex3D]
    var triangles: [Triangle3D]
    var sourceImageSize: CGSize
    static var empty: MeshModel { MeshModel(vertices: [], triangles: [], sourceImageSize: .zero) }
    var isEmpty: Bool { vertices.isEmpty || triangles.isEmpty }

    func scaled(widthMM: Float, heightMM: Float, depthMM: Float) -> MeshModel {
        guard !isEmpty else { return self }
        let b = boundingBox()
        let sx = widthMM / max(b.maxX - b.minX, 0.0001)
        let sy = heightMM / max(b.maxY - b.minY, 0.0001)
        let sz = depthMM / max(b.maxZ - b.minZ, 0.0001)
        let out = vertices.map {
            Vertex3D(x: ($0.x - b.minX - (b.maxX - b.minX) / 2) * sx,
                     y: ($0.y - b.minY - (b.maxY - b.minY) / 2) * sy,
                     z: ($0.z - b.minZ) * sz,
                     r: $0.r, g: $0.g, b: $0.b)
        }
        return MeshModel(vertices: out, triangles: triangles, sourceImageSize: sourceImageSize)
    }

    func boundingBox() -> (minX: Float, maxX: Float, minY: Float, maxY: Float, minZ: Float, maxZ: Float) {
        guard let first = vertices.first else { return (0, 1, 0, 1, 0, 1) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y, minZ = first.z, maxZ = first.z
        for v in vertices {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
            minZ = min(minZ, v.z); maxZ = max(maxZ, v.z)
        }
        return (minX, maxX, minY, maxY, minZ, maxZ)
    }

    func makeSceneGeometry() -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        var indices: [Int32] = []
        for t in triangles {
            indices.append(Int32(t.a)); indices.append(Int32(t.b)); indices.append(Int32(t.c))
        }
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: data,
                                         primitiveType: .triangles,
                                         primitiveCount: triangles.count,
                                         bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.systemCyan
        mat.specular.contents = UIColor.white
        mat.shininess = 0.45
        mat.isDoubleSided = true
        geometry.materials = [mat]
        return geometry
    }
}

enum STLExporter {
    static func writeTempSTL(mesh: MeshModel, name: String) throws -> URL {
        let text = asciiSTL(mesh: mesh, name: name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName(name)).stl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func asciiSTL(mesh: MeshModel, name: String) -> String {
        var out = "solid \(safeName(name))\n"
        for t in mesh.triangles where t.a < mesh.vertices.count && t.b < mesh.vertices.count && t.c < mesh.vertices.count {
            let a = mesh.vertices[t.a], b = mesh.vertices[t.b], c = mesh.vertices[t.c], n = normal(a, b, c)
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n    outer loop\n      vertex \(a.x) \(a.y) \(a.z)\n      vertex \(b.x) \(b.y) \(b.z)\n      vertex \(c.x) \(c.y) \(c.z)\n    endloop\n  endfacet\n"
        }
        return out + "endsolid \(safeName(name))\n"
    }

    fileprivate static func safeName(_ value: String) -> String {
        let mapped = value.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }
        let result = String(mapped)
        return result.isEmpty ? "ObjectForge3D" : result
    }

    private static func normal(_ a: Vertex3D, _ b: Vertex3D, _ c: Vertex3D) -> Vertex3D {
        var nx = (b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y)
        var ny = (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z)
        var nz = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        let len = max(sqrt(nx * nx + ny * ny + nz * nz), 0.00001)
        nx /= len; ny /= len; nz /= len
        return Vertex3D(x: nx, y: ny, z: nz)
    }
}

enum OBJExporter {
    static func writeTempOBJ(mesh: MeshModel, name: String) throws -> URL {
        let text = asciiOBJ(mesh: mesh, name: name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(STLExporter.safeName(name)).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func asciiOBJ(mesh: MeshModel, name: String) -> String {
        var out = "# ObjectForge3D colored OBJ\n"
        out += "o \(STLExporter.safeName(name))\n"
        for v in mesh.vertices {
            out += "v \(v.x) \(v.y) \(v.z) \(v.r) \(v.g) \(v.b)\n"
        }
        for t in mesh.triangles where t.a < mesh.vertices.count && t.b < mesh.vertices.count && t.c < mesh.vertices.count {
            out += "f \(t.a + 1) \(t.b + 1) \(t.c + 1)\n"
        }
        return out
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
