import SwiftUI
import PhotosUI
import SceneKit
import UIKit

struct ContentView: View {
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var baseMesh: MeshModel = .empty
    @State private var displayMesh: MeshModel = .empty
    @State private var settings = FrontLogicSettings()
    @State private var widthMM: Double = 80
    @State private var heightMM: Double = 80
    @State private var depthMM: Double = 18
    @State private var uniformScale = true
    @State private var status = "Import a photo to start."
    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var showShare = false

    private let builder = ReliefMeshBuilder()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    importPanel
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    if !displayMesh.isEmpty {
                        SceneKitPreview(mesh: displayMesh)
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(alignment: .topLeading) { confidenceLegend.padding(10) }
                        DimensionEditPanel(widthMM: $widthMM, heightMM: $heightMM, depthMM: $depthMM, uniformScale: $uniformScale, onApply: applyScale, onReset: resetScale)
                        exportControls
                    }
                    continuumCard
                    Text(status).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("ObjectForge 3D")
            .onChange(of: selectedPhoto) { _, newItem in Task { await loadPhoto(newItem) } }
            .sheet(isPresented: $showShare) { if let exportURL { ShareSheet(items: [exportURL]) } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photo → printable 3D part").font(.title2.bold())
            Text("FrontLogic v1 uses light/shading depth, edge boost, flat-back repair, and exact-size scaling to make practical STL parts.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var importPanel: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Import Photo", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            Button { buildMesh() } label: {
                Label(isWorking ? "Generating..." : "Generate 3D Relief", systemImage: "cube.transparent").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedImage == nil || isWorking)

            VStack(alignment: .leading, spacing: 10) {
                Text("FrontLogic Math").font(.headline)
                sliderRow("Relief Strength", value: Binding(get: { Double(settings.reliefStrength) }, set: { settings.reliefStrength = Float($0) }), range: 1...60, suffix: "mm")
                sliderRow("Base Thickness", value: Binding(get: { Double(settings.baseThickness) }, set: { settings.baseThickness = Float($0) }), range: 1...15, suffix: "mm")
                sliderRow("Edge Boost", value: Binding(get: { Double(settings.edgeBoost) }, set: { settings.edgeBoost = Float($0) }), range: 0...1.5, suffix: "")
                Toggle("Invert depth", isOn: Binding(get: { settings.invertDepth }, set: { settings.invertDepth = $0 }))
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(label).font(.caption.weight(.semibold)); Spacer(); Text("\(value.wrappedValue, specifier: "%.1f") \(suffix)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }

    private var confidenceLegend: some View {
        HStack(spacing: 8) { legendDot(.green, "visible"); legendDot(.yellow, "inferred"); legendDot(.red, "low confidence") }
            .font(.caption2.weight(.semibold)).padding(8).background(.thinMaterial).clipShape(Capsule())
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 7, height: 7); Text(text) }
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            Button { exportSTL() } label: { Label("Export STL", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            Text("Export STL, open in your slicer, then set material and print quality.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var continuumCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continuum Mode").font(.headline)
            Text("Use customer photos to create a rough replacement part, stretch it to exact measurements, export STL, and add quote notes.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Next build: broken/missing-area marker, material estimate, print-time estimate, and quote summary export.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        status = "Loading photo..."
        do {
            if let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                selectedImage = image
                baseMesh = .empty
                displayMesh = .empty
                status = "Photo loaded. Tap Generate 3D Relief."
            } else { status = "Could not load that photo." }
        } catch { status = "Photo load failed: \(error.localizedDescription)" }
    }

    private func buildMesh() {
        guard let selectedImage else { return }
        isWorking = true
        status = "Generating relief mesh..."
        let inputImage = selectedImage
        let inputSettings = settings
        let targetWidth = widthMM
        let targetHeight = heightMM
        let targetDepth = depthMM
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let mesh = try builder.buildRelief(from: inputImage, settings: inputSettings)
                let scaled = mesh.scaled(widthMM: Float(targetWidth), heightMM: Float(targetHeight), depthMM: Float(targetDepth))
                DispatchQueue.main.async {
                    self.baseMesh = mesh
                    self.displayMesh = scaled
                    self.status = "Generated \(mesh.vertices.count) vertices and \(mesh.triangles.count) triangles."
                    self.isWorking = false
                }
            } catch {
                DispatchQueue.main.async { self.status = "Generate failed: \(error.localizedDescription)"; self.isWorking = false }
            }
        }
    }

    private func applyScale() {
        guard !baseMesh.isEmpty else { return }
        displayMesh = baseMesh.scaled(widthMM: Float(widthMM), heightMM: Float(heightMM), depthMM: Float(depthMM))
        status = "Applied size: \(Int(widthMM)) x \(Int(heightMM)) x \(Int(depthMM)) mm."
    }

    private func resetScale() { widthMM = 80; heightMM = 80; depthMM = 18; applyScale() }

    private func exportSTL() {
        guard !displayMesh.isEmpty else { status = "Nothing to export yet."; return }
        do {
            let url = try STLExporter.writeTempSTL(mesh: displayMesh, name: "ObjectForge3D-Part")
            exportURL = url
            showShare = true
            status = "STL ready: \(url.lastPathComponent)"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
}

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
            HStack { Button("Apply Size", action: onApply).buttonStyle(.borderedProminent); Button("Reset", action: onReset).buttonStyle(.bordered) }
        }
        .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 18))
        .onChange(of: widthMM) { oldValue, newValue in
            if uniformScale { let ratio = max(newValue / max(oldValue, 0.01), 0.01); heightMM = max(10, min(300, heightMM * ratio)) }
        }
    }

    private func dimensionRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(label).font(.subheadline.weight(.semibold)); Spacer(); Text("\(Int(value.wrappedValue)) mm").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            HStack { Button("-") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) }.buttonStyle(.bordered); Slider(value: value, in: range); Button("+") { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) }.buttonStyle(.bordered) }
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
    mutating func clamp() {
        gridSize = max(16, min(140, gridSize))
        reliefStrength = max(0.5, min(80, reliefStrength))
        baseThickness = max(0.5, min(25, baseThickness))
        smoothingPasses = max(0, min(8, smoothingPasses))
        edgeBoost = max(0, min(2, edgeBoost))
    }
}

final class ReliefMeshBuilder {
    func buildRelief(from image: UIImage, settings rawSettings: FrontLogicSettings) throws -> MeshModel {
        var settings = rawSettings
        settings.clamp()
        guard let cgImage = image.cgImage else { throw FrontLogicError.invalidImage }
        let grid = settings.gridSize
        let luminance = try sampleLuminance(cgImage: cgImage, grid: grid)
        var heights = makeHeightMap(luminance: luminance, grid: grid, settings: settings)
        for _ in 0..<settings.smoothingPasses { heights = smooth(heights, grid: grid) }
        return makeFlatBackMesh(heights: heights, grid: grid, imageSize: image.size)
    }

    private func sampleLuminance(cgImage: CGImage, grid: Int) throws -> [Float] {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: grid * grid * 4)
        guard let bitmap = CGContext(data: &bytes, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FrontLogicError.bitmapFailed }
        bitmap.interpolationQuality = .high
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        var lum = [Float](repeating: 0, count: grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let i = (y * grid + x) * 4
                let r = Float(bytes[i]) / 255
                let g = Float(bytes[i + 1]) / 255
                let b = Float(bytes[i + 2]) / 255
                let a = Float(bytes[i + 3]) / 255
                lum[y * grid + x] = (0.2126 * r + 0.7152 * g + 0.0722 * b) * a
            }
        }
        return lum
    }

    private func makeHeightMap(luminance: [Float], grid: Int, settings: FrontLogicSettings) -> [Float] {
        var heights = [Float](repeating: 0, count: grid * grid)
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = y * grid + x
                let l = luminance[idx]
                let depthSignal = settings.invertDepth ? (1 - l) : l
                let edge = localEdge(luminance, grid: grid, x: x, y: y)
                let boosted = max(0, min(1, depthSignal + edge * settings.edgeBoost))
                heights[idx] = settings.baseThickness + boosted * settings.reliefStrength
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

    private func smooth(_ values: [Float], grid: Int) -> [Float] {
        var out = values
        for y in 0..<grid {
            for x in 0..<grid {
                var sum: Float = 0
                var count: Float = 0
                for yy in max(0, y - 1)...min(grid - 1, y + 1) {
                    for xx in max(0, x - 1)...min(grid - 1, x + 1) { sum += values[yy * grid + xx]; count += 1 }
                }
                out[y * grid + x] = sum / max(count, 1)
            }
        }
        return out
    }

    private func makeFlatBackMesh(heights: [Float], grid: Int, imageSize: CGSize) -> MeshModel {
        var vertices: [Vertex3D] = []
        var triangles: [Triangle3D] = []
        for y in 0..<grid { for x in 0..<grid { vertices.append(Vertex3D(x: Float(x) / Float(grid - 1) - 0.5, y: 0.5 - Float(y) / Float(grid - 1), z: heights[y * grid + x])) } }
        let bottomOffset = vertices.count
        for y in 0..<grid { for x in 0..<grid { vertices.append(Vertex3D(x: Float(x) / Float(grid - 1) - 0.5, y: 0.5 - Float(y) / Float(grid - 1), z: 0)) } }
        func top(_ x: Int, _ y: Int) -> Int { y * grid + x }
        func bottom(_ x: Int, _ y: Int) -> Int { bottomOffset + y * grid + x }
        for y in 0..<(grid - 1) {
            for x in 0..<(grid - 1) {
                let a = top(x, y), b = top(x + 1, y), c = top(x, y + 1), d = top(x + 1, y + 1)
                triangles.append(Triangle3D(a: a, b: c, c: b)); triangles.append(Triangle3D(a: b, b: c, c: d))
                let ba = bottom(x, y), bb = bottom(x + 1, y), bc = bottom(x, y + 1), bd = bottom(x + 1, y + 1)
                triangles.append(Triangle3D(a: ba, b: bb, c: bc)); triangles.append(Triangle3D(a: bb, b: bd, c: bc))
            }
        }
        for x in 0..<(grid - 1) { addWall(topA: top(x, 0), topB: top(x + 1, 0), bottomA: bottom(x, 0), bottomB: bottom(x + 1, 0), triangles: &triangles); addWall(topA: top(x + 1, grid - 1), topB: top(x, grid - 1), bottomA: bottom(x + 1, grid - 1), bottomB: bottom(x, grid - 1), triangles: &triangles) }
        for y in 0..<(grid - 1) { addWall(topA: top(0, y + 1), topB: top(0, y), bottomA: bottom(0, y + 1), bottomB: bottom(0, y), triangles: &triangles); addWall(topA: top(grid - 1, y), topB: top(grid - 1, y + 1), bottomA: bottom(grid - 1, y), bottomB: bottom(grid - 1, y + 1), triangles: &triangles) }
        return MeshModel(vertices: vertices, triangles: triangles, sourceImageSize: imageSize)
    }

    private func addWall(topA: Int, topB: Int, bottomA: Int, bottomB: Int, triangles: inout [Triangle3D]) {
        triangles.append(Triangle3D(a: topA, b: bottomA, c: topB)); triangles.append(Triangle3D(a: topB, b: bottomA, c: bottomB))
    }
}

enum FrontLogicError: LocalizedError { case invalidImage, bitmapFailed; var errorDescription: String? { self == .invalidImage ? "Could not read selected image." : "Could not create image sampler." } }

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
        let out = vertices.map { Vertex3D(x: ($0.x - b.minX - (b.maxX - b.minX) / 2) * sx, y: ($0.y - b.minY - (b.maxY - b.minY) / 2) * sy, z: ($0.z - b.minZ) * sz) }
        return MeshModel(vertices: out, triangles: triangles, sourceImageSize: sourceImageSize)
    }

    func boundingBox() -> (minX: Float, maxX: Float, minY: Float, maxY: Float, minZ: Float, maxZ: Float) {
        guard let first = vertices.first else { return (0, 1, 0, 1, 0, 1) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y, minZ = first.z, maxZ = first.z
        for v in vertices { minX = min(minX, v.x); maxX = max(maxX, v.x); minY = min(minY, v.y); maxY = max(maxY, v.y); minZ = min(minZ, v.z); maxZ = max(maxZ, v.z) }
        return (minX, maxX, minY, maxY, minZ, maxZ)
    }

    func makeSceneGeometry() -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        var indices: [Int32] = []
        for t in triangles { indices.append(Int32(t.a)); indices.append(Int32(t.b)); indices.append(Int32(t.c)) }
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: triangles.count, bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial(); mat.diffuse.contents = UIColor.systemTeal; mat.specular.contents = UIColor.white; mat.shininess = 0.35; mat.isDoubleSided = true
        geometry.materials = [mat]
        return geometry
    }
}

struct SceneKitPreview: UIViewRepresentable {
    var mesh: MeshModel
    func makeUIView(context: Context) -> SCNView { makeView() }
    func updateUIView(_ view: SCNView, context: Context) { view.scene = makeScene(); view.allowsCameraControl = true }
    private func makeView() -> SCNView { let view = SCNView(); view.scene = makeScene(); view.backgroundColor = .secondarySystemBackground; view.allowsCameraControl = true; view.autoenablesDefaultLighting = true; return view }
    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0, 0, 160); scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.position = SCNVector3(0, 80, 120); scene.rootNode.addChildNode(light)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.color = UIColor(white: 0.45, alpha: 1); scene.rootNode.addChildNode(ambient)
        if !mesh.isEmpty { let node = SCNNode(geometry: mesh.makeSceneGeometry()); node.eulerAngles.x = -.pi / 7; node.eulerAngles.y = .pi / 7; scene.rootNode.addChildNode(node) }
        return scene
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
    private static func normal(_ a: Vertex3D, _ b: Vertex3D, _ c: Vertex3D) -> Vertex3D { var nx = (b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y); var ny = (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z); var nz = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x); let len = max(sqrt(nx * nx + ny * ny + nz * nz), 0.00001); nx /= len; ny /= len; nz /= len; return Vertex3D(x: nx, y: ny, z: nz) }
    private static func safeName(_ value: String) -> String { let mapped = value.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }; let result = String(mapped); return result.isEmpty ? "ObjectForge3D" : result }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
