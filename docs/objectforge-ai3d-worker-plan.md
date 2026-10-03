# ObjectForge AI Image-to-3D Worker Plan

This document records the lightweight iPhone + external worker approach for ObjectForge 3D.

## Goal

Keep the iOS IPA small and practical while allowing heavy image-to-3D models to run on Sidekick / Frankie / the Dell Precision / cloud worker later.

ObjectForge should:

1. capture or import an image on iPhone;
2. crop, mask, and remove background;
3. send the prepared image to an external worker when available;
4. receive OBJ / GLB / PLY / STL output;
5. open the result inside ObjectForge's preview / repair / scale workspace;
6. export printable STL.

## Engines to support

### 1. TripoSR

First practical worker target.

- Open-source repo: https://github.com/VAST-AI-Research/TripoSR
- Purpose: fast single-image 3D reconstruction.
- Output lane: mesh file returned to ObjectForge.
- Worker notes: Python / PyTorch path, not bundled into IPA.

### 2. Microsoft TRELLIS / TRELLIS.2

High-quality research worker target.

- Official project page: https://microsoft.github.io/TRELLIS/
- Official repo: https://github.com/microsoft/TRELLIS
- TRELLIS.2 repo: https://github.com/microsoft/TRELLIS.2
- Purpose: high-fidelity image-to-3D asset generation.
- Worker notes: likely heavier than TripoSR; target Sidekick / desktop / cloud worker first.

### 3. VFusion3D

Research/reference target.

- Reference article: https://python.plainenglish.io/generate-your-own-3d-models-with-vfusion3d-4f3a7e6630b5
- Purpose: future experiment lane for image-to-3D generation.
- Worker notes: evaluate after TripoSR/TRELLIS pipeline is stable.

### 4. Other open models

Track later:

- Stable Fast 3D
- Hunyuan3D
- Shap-E style tools
- Future local GGUF/GGML/C++ implementations when practical

## API shape

ObjectForge should talk to a worker with a simple API:

```http
GET /health
POST /generate
GET /jobs/{job_id}
GET /jobs/{job_id}/download
```

### Request

```json
{
  "engine": "triposr",
  "target_format": "glb",
  "background_removed": true,
  "repair_for_printing": false,
  "notes": "dog photo test"
}
```

The actual image should be uploaded as multipart form data.

### Response

```json
{
  "job_id": "uuid",
  "status": "queued",
  "engine": "triposr"
}
```

### Completed job

```json
{
  "job_id": "uuid",
  "status": "complete",
  "engine": "triposr",
  "output_format": "glb",
  "download_url": "/jobs/uuid/download",
  "warnings": []
}
```

## iOS UI target

Add later as an ObjectForge mode:

- AI 3D Worker tab/card
- Engine picker: Fast Draft / TripoSR / TRELLIS / VFusion
- Worker URL field
- Send current photo/mask
- Poll job status
- Download generated model
- Open in repair workspace

## Safety and size rule

Do not bundle large model weights into the IPA. Keep the app usable offline for photo relief and LiDAR/OBJ import. Heavy AI generation belongs in the external worker path.
