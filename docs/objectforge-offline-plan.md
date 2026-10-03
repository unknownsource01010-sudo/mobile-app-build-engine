# ObjectForge 3D Offline Plan

## Goal
Make ObjectForge useful without paid cloud services and without internet after the initial setup/download phase.

## Offline levels

### Level 1: Fully offline on iPhone
These features should work entirely on-device:

- Photo import
- Crop/rotate/manual cleanup
- Simple background removal based on edge/background color and threshold sliders
- Relief/depth-map generation from a single photo
- Invert depth / subject raised controls
- Mesh preview
- Mesh stats
- Scale to millimeters
- Export STL/OBJ to Files
- Import and preview local OBJ/STL/GLB/USDZ where supported
- LiDAR scan mode using ARKit scene reconstruction on supported iPhone/iPad Pro hardware
- Local project history stored in app sandbox / Files

This level does not run heavy AI reconstruction models. It gives a reliable offline utility app.

### Level 2: Offline LAN worker
The iPhone app talks to a local machine on the same Wi-Fi/hotspot/LAN:

- Sidekick OS / Frankie machine
- Dell Precision workstation
- local Mac/Linux box

The worker hosts `/generate`, `/jobs/{id}`, and `/download` endpoints. The phone sends an image, the worker runs the selected engine, and the phone downloads OBJ/GLB/STL back.

This works without internet after dependencies and model weights are already installed.

Candidate engines:

- TripoSR: first practical target; single image to 3D; Python worker; GPU strongly preferred.
- TRELLIS: higher-quality target; likely heavier; keep as advanced engine slot.
- VFusion3D: research/experimental lane.
- Mock engine: tiny offline placeholder output for testing UI and file flow.

### Level 3: Sneakernet offline mode
For no network at all:

1. iPhone exports prepared input image + metadata JSON.
2. User transfers it by USB, AirDrop, local Files, or external drive.
3. Worker processes the job offline.
4. Worker writes OBJ/GLB/STL results.
5. User imports the result back into ObjectForge.

This is slower but fully disconnected.

## What cannot realistically be fully offline inside the first IPA

- Heavy AI models such as TripoSR/TRELLIS bundled inside the iPhone app.
- Large model weights shipped with the IPA.
- Fast on-device AI 3D reconstruction without major optimization/Core ML conversion.

Keep the first IPA lightweight and reliable. Add heavyweight AI as an optional local worker path.

## Recommended build order

1. Finish on-device Photo Relief + background removal.
2. Add LiDAR Scan Mode v0 using ARKit scene reconstruction.
3. Add local import/repair/export workspace.
4. Add AI Worker tab that can point to `http://<local-ip>:8787`.
5. Add offline LAN worker install scripts for Sidekick/Dell.
6. Add model-cache/downloader scripts so weights can be downloaded once, then reused offline.
7. Add sneakernet export/import job bundles.

## UX requirement

The app should show three clear modes:

- On-device offline: always works.
- Local worker: works when a local server is reachable.
- Cloud/remote: optional later, never required.

No feature should silently depend on the internet. If a model or server is missing, the app should explain exactly what is missing and keep the on-device tools available.