import SwiftUI
import PhotosUI
import SceneKit
import UIKit

struct ObjectForgeMainView: View {
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
                            .frame(maxHeight: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    if !displayMesh.isEmpty {
                        FixedSceneKitPreview(mesh: displayMesh)
                            .frame(height: 390)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(alignment: .topLeading) { confidenceLegend.padding(10) }
                            .overlay(alignment: .topTrailing) {
                                Text("PREVIEW FIX 1")
                                    .font(.caption2.weight(.black))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(.thinMaterial)
                                    .clipShape(Capsule())
                                    .padding(10)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Text("drag / pinch / rotate")
                                    .font(.caption2.weight(.semibold))
                                    .padding(8)
                                    .background(.thinMaterial)
                                    .clipShape(Capsule())
                                    .padding(10)
                            }
                            .id(displayMesh.vertices.count + displayMesh.triangles.count + Int(widthMM) + Int(heightMM) + Int(depthMM))

                        MeshStatsStrip(mesh: displayMesh)

                        DimensionEditPanel(widthMM: $widthMM,
                                           heightMM: $heightMM,
                                           depthMM: $depthMM,
                                           uniformScale: $uniformScale,
                                           onApply: applyScale,
                                           onReset: resetScale)
                        exportControls
                    } else {
                        placeholderPreview
                    }

                    continuumCard
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("ObjectForge 3D")
            .onChange(of: selectedPhoto) { _, newItem in
                Task { await loadPhoto(newItem) }
            }
            .sheet(isPresented: $showShare) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photo → printable 3D part")
                .font(.title2.bold())
            Text("FrontLogic v1 turns one photo into a flat-back relief mesh, then lets you resize and export STL for repair parts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var importPanel: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Import Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            Button { buildMesh() } label: {
                Label(isWorking ? "Generating..." : "Generate 3D Relief", systemImage: "cube.transparent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedImage == nil || isWorking)

            VStack(alignment: .leading, spacing: 10) {
                Text("FrontLogic Math")
                    .font(.headline)
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

    private var placeholderPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("3D preview appears here after generation")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Preview Fix 1 will auto-center, brighten, and wireframe the model.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label).font(.caption.weight(.semibold))
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f") \(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var confidenceLegend: some View {
        HStack(spacing: 8) {
            legendDot(.green, "visible")
            legendDot(.yellow, "inferred")
            legendDot(.red, "low confidence")
        }
        .font(.caption2.weight(.semibold))
        .padding(8)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            Button { exportSTL() } label: {
                Label("Export STL", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Export STL, open in your slicer, then set material and print quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var continuumCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continuum Mode")
                .font(.headline)
            Text("Use customer photos to rough in a replacement part, stretch it to exact measurements, export STL, and add quote notes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Next build: broken/missing-area marker, material estimate, print-time estimate, and quote summary export.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
            } else {
                status = "Could not load that photo."
            }
        } catch {
            status = "Photo load failed: \(error.localizedDescription)"
        }
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
                    self.status = "Preview Fix 1: generated \(scaled.vertices.count) vertices / \(scaled.triangles.count) triangles."
                    self.isWorking = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Generate failed: \(error.localizedDescription)"
                    self.isWorking = false
                }
            }
        }
    }

    private func applyScale() {
        guard !baseMesh.isEmpty else { return }
        displayMesh = baseMesh.scaled(widthMM: Float(widthMM), heightMM: Float(heightMM), depthMM: Float(depthMM))
        status = "Applied size: \(Int(widthMM)) x \(Int(heightMM)) x \(Int(depthMM)) mm."
    }

    private func resetScale() {
        widthMM = 80
        heightMM = 80
        depthMM = 18
        applyScale()
    }

    private func exportSTL() {
        guard !displayMesh.isEmpty else {
            status = "Nothing to export yet."
            return
        }
        do {
            let url = try STLExporter.writeTempSTL(mesh: displayMesh, name: "ObjectForge3D-Part")
            exportURL = url
            showShare = true
            status = "STL ready: \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }
}

struct MeshStatsStrip: View {
    let mesh: MeshModel

    private var dimsText: String {
        let b = mesh.boundingBox()
        let w = Int((b.maxX - b.minX).rounded())
        let h = Int((b.maxY - b.minY).rounded())
        let d = Int((b.maxZ - b.minZ).rounded())
        return "\(w) × \(h) × \(d) mm"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mesh generated", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text(dimsText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Vertices: \(mesh.vertices.count)")
                Text("Triangles: \(mesh.triangles.count)")
                Text("Auto-fit preview")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct FixedSceneKitPreview: UIViewRepresentable {
    var mesh: MeshModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        installScene(on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        installScene(on: view)
    }

    private func installScene(on view: SCNView) {
        let scene = makeScene()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "objectforge-camera", recursively: false)
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.black

        let bounds = mesh.boundingBox()
        let width = max(bounds.maxX - bounds.minX, 1)
        let height = max(bounds.maxY - bounds.minY, 1)
        let depth = max(bounds.maxZ - bounds.minZ, 1)
        let maxDim = max(width, max(height, depth))
        let centerX = (bounds.minX + bounds.maxX) / 2
        let centerY = (bounds.minY + bounds.maxY) / 2
        let centerZ = (bounds.minZ + bounds.maxZ) / 2

        let target = SCNNode()
        target.name = "objectforge-target"
        target.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(target)

        if !mesh.isEmpty {
            let solidGeometry = mesh.makeSceneGeometry()
            let solidMaterial = SCNMaterial()
            solidMaterial.diffuse.contents = UIColor.systemCyan
            solidMaterial.emission.contents = UIColor(red: 0.0, green: 0.18, blue: 0.24, alpha: 1.0)
            solidMaterial.specular.contents = UIColor.white
            solidMaterial.shininess = 0.9
            solidMaterial.isDoubleSided = true
            solidGeometry.materials = [solidMaterial]

            let solidNode = SCNNode(geometry: solidGeometry)
            solidNode.name = "objectforge-solid-mesh"
            solidNode.position = SCNVector3(-centerX, -centerY, -centerZ)
            solidNode.eulerAngles = SCNVector3(-Float.pi / 8, Float.pi / 10, 0)
            scene.rootNode.addChildNode(solidNode)

            let wireGeometry = mesh.makeSceneGeometry()
            let wireMaterial = SCNMaterial()
            wireMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.78)
            wireMaterial.emission.contents = UIColor.white.withAlphaComponent(0.48)
            wireMaterial.isDoubleSided = true
            wireMaterial.fillMode = .lines
            wireGeometry.materials = [wireMaterial]

            let wireNode = SCNNode(geometry: wireGeometry)
            wireNode.name = "objectforge-wire-mesh"
            wireNode.position = solidNode.position
            wireNode.eulerAngles = solidNode.eulerAngles
            wireNode.scale = SCNVector3(1.002, 1.002, 1.002)
            wireNode.renderingOrder = 20
            scene.rootNode.addChildNode(wireNode)
        }

        let camera = SCNNode()
        camera.name = "objectforge-camera"
        let scnCamera = SCNCamera()
        scnCamera.usesOrthographicProjection = true
        scnCamera.orthographicScale = Double(max(width, height) * 1.35)
        scnCamera.zNear = 0.01
        scnCamera.zFar = Double(max(maxDim * 40, Float(2000)))
        camera.camera = scnCamera
        camera.position = SCNVector3(0, -maxDim * 0.92, maxDim * 1.55)
        let lookAt = SCNLookAtConstraint(target: target)
        lookAt.isGimbalLockEnabled = true
        camera.constraints = [lookAt]
        scene.rootNode.addChildNode(camera)

        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .omni
        keyLight.light?.intensity = 2600
        keyLight.position = SCNVector3(-maxDim * 0.8, -maxDim * 1.2, maxDim * 2.1)
        scene.rootNode.addChildNode(keyLight)

        let sideLight = SCNNode()
        sideLight.light = SCNLight()
        sideLight.light?.type = .directional
        sideLight.light?.intensity = 850
        sideLight.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 5, 0)
        scene.rootNode.addChildNode(sideLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .ambient
        fillLight.light?.color = UIColor(white: 0.72, alpha: 1)
        scene.rootNode.addChildNode(fillLight)

        return scene
    }
}
