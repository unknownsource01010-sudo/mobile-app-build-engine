import SwiftUI
import ARKit
import RealityKit
import ModelIO
import MetalKit

struct LiDARScanModeView: View {
    @State private var isScanning = true
    @State private var exportToken = 0
    @State private var scanName = "ObjectForge-LiDAR-Scan"
    @State private var status = "LiDAR mode uses ARKit scene reconstruction. Move slowly around the part or area."
    @State private var exportURL: URL?
    @State private var showShare = false

    private var lidarSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) ||
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                header

                if lidarSupported {
                    LiDARARViewContainer(isScanning: $isScanning,
                                         exportToken: $exportToken,
                                         scanName: $scanName,
                                         status: $status,
                                         exportURL: $exportURL,
                                         showShare: $showShare)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .topLeading) {
                            scanBadge.padding(10)
                        }
                        .frame(maxHeight: .infinity)
                } else {
                    unsupportedCard
                    Spacer()
                }

                controls
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .navigationTitle("LiDAR Scan")
            .sheet(isPresented: $showShare) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Scan Mode")
                .font(.title2.bold())
            Text("Experimental ARKit LiDAR capture. Exports OBJ first; repair/convert-to-STL comes next.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scanBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isScanning ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(isScanning ? "SCANNING" : "PAUSED")
                .font(.caption2.monospaced().weight(.bold))
        }
        .padding(8)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }

    private var unsupportedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("LiDAR not available on this device", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("This mode needs an iPhone/iPad with LiDAR. Photo Forge mode still works without LiDAR.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            TextField("Scan name", text: $scanName)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)

            HStack {
                Button(isScanning ? "Pause" : "Resume") {
                    isScanning.toggle()
                }
                .buttonStyle(.bordered)

                Button {
                    exportToken += 1
                } label: {
                    Label("Export OBJ", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!lidarSupported)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct LiDARARViewContainer: UIViewRepresentable {
    @Binding var isScanning: Bool
    @Binding var exportToken: Int
    @Binding var scanName: String
    @Binding var status: String
    @Binding var exportURL: URL?
    @Binding var showShare: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        view.environment.sceneUnderstanding.options.insert(.occlusion)
        view.debugOptions.insert(.showSceneUnderstanding)
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.parent = self
        if isScanning {
            context.coordinator.runSession(on: view)
        } else {
            view.session.pause()
        }

        if exportToken != context.coordinator.lastExportToken {
            context.coordinator.lastExportToken = exportToken
            context.coordinator.exportOBJ(from: view)
        }
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        var parent: LiDARARViewContainer
        var lastExportToken = 0
        private var didStart = false

        init(_ parent: LiDARARViewContainer) {
            self.parent = parent
        }

        func configure(_ view: ARView) {
            view.session.delegate = self
            runSession(on: view)
        }

        func runSession(on view: ARView) {
            guard !didStart else { return }
            didStart = true

            guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ||
                  ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
                parent.status = "This device does not support ARKit LiDAR mesh reconstruction."
                return
            }

            let config = ARWorldTrackingConfiguration()
            config.environmentTexturing = .automatic

            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                config.sceneReconstruction = .meshWithClassification
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }

            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }

            view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            parent.status = "LiDAR session started. Move slowly so mesh anchors build up before exporting."
        }

        func exportOBJ(from view: ARView) {
            guard let frame = view.session.currentFrame else {
                parent.status = "No AR frame yet. Keep scanning a moment, then export again."
                return
            }

            let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            guard !anchors.isEmpty else {
                parent.status = "No mesh anchors captured yet. Move around the subject slowly."
                return
            }

            guard let device = MTLCreateSystemDefaultDevice() else {
                parent.status = "Metal device unavailable, cannot export OBJ."
                return
            }

            let asset = MDLAsset()
            for anchor in anchors {
                let mesh = anchor.geometry.objectForgeMDLMesh(device: device, modelMatrix: anchor.transform)
                asset.add(mesh)
            }

            do {
                let fileName = Self.safeFileName(parent.scanName.isEmpty ? "ObjectForge-LiDAR-Scan" : parent.scanName)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName).obj")
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try asset.export(to: url)
                parent.exportURL = url
                parent.showShare = true
                parent.status = "OBJ exported from \(anchors.count) LiDAR mesh anchors."
            } catch {
                parent.status = "OBJ export failed: \(error.localizedDescription)"
            }
        }

        private static func safeFileName(_ value: String) -> String {
            let mapped = value.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }
            let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return result.isEmpty ? "ObjectForge-LiDAR-Scan" : result
        }
    }
}

private extension ARMeshGeometry {
    func objectForgeVertex(at index: Int) -> SIMD3<Float> {
        let pointer = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * index)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    func objectForgeMDLMesh(device: MTLDevice, modelMatrix: simd_float4x4) -> MDLMesh {
        let allocator = MTKMeshBufferAllocator(device: device)

        var transformedVertices: [SIMD3<Float>] = []
        transformedVertices.reserveCapacity(vertices.count)

        for index in 0..<vertices.count {
            let local = objectForgeVertex(at: index)
            let world = modelMatrix * SIMD4<Float>(local.x, local.y, local.z, 1)
            transformedVertices.append(SIMD3<Float>(world.x, world.y, world.z))
        }

        let vertexData = transformedVertices.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)

        let indexCount = faces.count * faces.indexCountPerPrimitive
        let indexData = Data(bytes: faces.buffer.contents(), count: faces.bytesPerIndex * indexCount)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)
        let indexType: MDLIndexBitDepth = faces.bytesPerIndex == 2 ? .uInt16 : .uInt32

        let submesh = MDLSubmesh(indexBuffer: indexBuffer,
                                 indexCount: indexCount,
                                 indexType: indexType,
                                 geometryType: .triangles,
                                 material: nil)

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                       format: .float3,
                                                       offset: 0,
                                                       bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        return MDLMesh(vertexBuffer: vertexBuffer,
                       vertexCount: transformedVertices.count,
                       descriptor: descriptor,
                       submeshes: [submesh])
    }
}
