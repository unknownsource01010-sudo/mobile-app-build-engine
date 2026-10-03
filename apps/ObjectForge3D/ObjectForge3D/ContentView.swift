import SwiftUI
import SceneKit
import UIKit

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
    var gridSize: Int = 72
    var reliefStrength: Float = 12
    var baseThickness: Float = 3
    var smoothingPasses: Int = 2
    var invertDepth: Bool = false
    var edgeBoost: Float = 0.35
    var removeBackground: Bool = true
    var backgroundThreshold: Float = 0.16
    var subjectRaised: Bool = true

    mutating func clamp() {
        gridSize = max(16, min(140, gridSize))
        reliefStrength = max(0.5, min(80, reliefStrength))
        baseThickness = max(0.5, min(25, baseThickness))
        smoothingPasses = max(0, min(8, smoothingPasses))
        edgeBoost = max(0, min(2, edgeBoost))
        backgroundThreshold = max(0.03, min(0.45, backgroundThreshold))
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
        let mask = settings.removeBackground ? makeForegroundMask(samples: samples, grid: grid, threshold: settings.backgroundThreshold) : [Float](repeating: 1, count: grid * grid)
        var heights = makeHeightMap(luminance: luminance, mask: mask, grid: grid, settings: settings)
        for _ in 0..<settings.smoothingPasses { heights = smooth(heights, grid: grid, mask: mask) }
        return makeFlatBackMesh(heights: heights, mask: mask, grid: grid, imageSize: image.size)
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
                let edge = localEdge(samples.map { $0.l }, grid: grid, x: x, y: y)
                let centerBias = centerWeight(x: x, y: y, grid: grid) * 0.10
                let score = colorDistance * 0.72 + lumDistance * 0.45 + edge * 0.55 + centerBias
                raw[idx] = smoothStep(edge0: threshold * 0.55, edge1: threshold * 1.55, x: score)
            }
        }
        var smoothed = raw
        for _ in 0..<2 { smoothed = smoothMask(smoothed, grid: grid) }
        return smoothed.map { $0 < 0.18 ? 0 : min(1, $0) }
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

    private func makeHeightMap(luminance: [Float], mask: [Float], grid: Int, settings: FrontLogicSettings) -> [Float] {
        var heights = [Float](repeating: settings.baseThickness, count: grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = y * grid + x
                let subject = max(0, min(1, mask[idx]))
                let l = luminance[idx]
                let depthSignal = settings.invertDepth ? (1 - l) : l
                let edge = localEdge(luminance, grid: grid, x: x, y: y)
                let subjectLift: Float = settings.subjectRaised ? 0.26 : 0
                let detail = max(0, min(1, depthSignal * 0.72 + edge * settings.edgeBoost + subjectLift))
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

    private func makeFlatBackMesh(heights: [Float], mask: [Float], grid: Int, imageSize: CGSize) -> MeshModel {
        var vertices: [Vertex3D] = []
        var triangles: [Triangle3D] = []
        for y in 0..<grid {
            for x in 0..<grid {
                vertices.append(Vertex3D(x: Float(x) / Float(grid - 1) - 0.5,
                                         y: 0.5 - Float(y) / Float(grid - 1),
                                         z: heights[y * grid + x]))
            }
        }
        let bottomOffset = vertices.count
        for y in 0..<grid {
            for x in 0..<grid {
                vertices.append(Vertex3D(x: Float(x) / Float(grid - 1) - 0.5,
                                         y: 0.5 - Float(y) / Float(grid - 1),
                                         z: 0))
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

struct Vertex3D: Hashable { var x: Float; var y: Float; var z: Float }
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
                     z: ($0.z - b.minZ) * sz)
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

    private static func normal(_ a: Vertex3D, _ b: Vertex3D, _ c: Vertex3D) -> Vertex3D {
        var nx = (b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y)
        var ny = (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z)
        var nz = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        let len = max(sqrt(nx * nx + ny * ny + nz * nz), 0.00001)
        nx /= len; ny /= len; nz /= len
        return Vertex3D(x: nx, y: ny, z: nz)
    }

    private static func safeName(_ value: String) -> String {
        let mapped = value.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }
        let result = String(mapped)
        return result.isEmpty ? "ObjectForge3D" : result
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}