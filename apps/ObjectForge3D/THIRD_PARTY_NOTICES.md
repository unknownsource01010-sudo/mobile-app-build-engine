# ObjectForge 3D Third-Party Notices

## SwiftUI-LiDAR reference

ObjectForge 3D LiDAR Scan Mode uses an original implementation inspired by the public `cedanmisquith/SwiftUI-LiDAR` project.

- Repository: https://github.com/cedanmisquith/SwiftUI-LiDAR
- License: MIT License
- Useful concepts reviewed: ARKit LiDAR scene reconstruction, `ARMeshAnchor` capture, Model I/O mesh asset export, and OBJ output.

The ObjectForge implementation keeps attribution here and does not copy the project wholesale.

## KIRI Engine 3D Scan Prep reference

The `Kiri-Innovation/3D-Scan-Preparation-Tool-by-KIRI-Engine` repository was reviewed as a design reference for scan-prep workflows such as frame extraction, blur/weak-image detection, AI masks, and scan-focused image processing.

- Repository: https://github.com/Kiri-Innovation/3D-Scan-Preparation-Tool-by-KIRI-Engine
- License: GNU Affero General Public License v3.0

Because this project is AGPL-3.0, ObjectForge should not copy its code directly into the iOS app unless ObjectForge's licensing plan is intentionally changed to be compatible with AGPL obligations. Safe use for now: study workflow ideas, keep independent implementation, or isolate any AGPL code as a clearly separated tool/service with its license preserved.
