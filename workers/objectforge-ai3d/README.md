# ObjectForge AI 3D Worker

This folder is the future external worker for heavy image-to-3D engines.

The iPhone app should stay light. The worker can run on Sidekick / Frankie / desktop GPU / cloud later.

## First API goals

- `GET /health`
- `POST /generate`
- `GET /jobs/{job_id}`
- `GET /jobs/{job_id}/download`

## Engine adapters

Planned adapters:

- `triposr` — first practical target.
- `trellis` — high-quality Microsoft TRELLIS/TRELLIS.2 lane.
- `vfusion` — research lane.
- `mock` — local test engine that returns a placeholder result so the iOS app can be tested before GPU setup.

## Run later

```bash
cd workers/objectforge-ai3d
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8733
```

## iPhone / ObjectForge flow

1. ObjectForge removes background or prepares a mask.
2. ObjectForge sends image to this worker.
3. Worker runs selected engine.
4. Worker returns OBJ/GLB/PLY/STL.
5. ObjectForge imports, previews, repairs, scales, and exports printable STL.
