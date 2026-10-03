from __future__ import annotations

import shutil
import uuid
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

APP_NAME = "ObjectForge AI 3D Worker"
BASE_DIR = Path(__file__).resolve().parent
JOB_DIR = BASE_DIR / "jobs"
JOB_DIR.mkdir(parents=True, exist_ok=True)

EngineName = Literal["mock", "triposr", "trellis", "vfusion"]
JobStatus = Literal["queued", "running", "complete", "failed"]


@dataclass
class JobRecord:
    job_id: str
    engine: str
    status: JobStatus
    input_path: str
    output_path: str | None = None
    output_format: str = "glb"
    message: str = "queued"


class JobResponse(BaseModel):
    job_id: str
    engine: str
    status: JobStatus
    output_format: str
    message: str
    download_url: str | None = None


app = FastAPI(title=APP_NAME, version="0.1.0")
_jobs: dict[str, JobRecord] = {}


@app.get("/health")
def health() -> dict[str, object]:
    return {
        "ok": True,
        "name": APP_NAME,
        "engines": ["mock", "triposr", "trellis", "vfusion"],
        "note": "Heavy engines are adapter placeholders until model setup is installed.",
    }


@app.post("/generate", response_model=JobResponse)
async def generate(
    image: UploadFile = File(...),
    engine: EngineName = Form("mock"),
    target_format: str = Form("glb"),
    background_removed: bool = Form(False),
    repair_for_printing: bool = Form(False),
    notes: str = Form(""),
) -> JobResponse:
    job_id = str(uuid.uuid4())
    job_path = JOB_DIR / job_id
    job_path.mkdir(parents=True, exist_ok=True)

    suffix = Path(image.filename or "input.png").suffix or ".png"
    input_path = job_path / f"input{suffix}"
    with input_path.open("wb") as f:
        shutil.copyfileobj(image.file, f)

    record = JobRecord(
        job_id=job_id,
        engine=engine,
        status="running",
        input_path=str(input_path),
        output_format=target_format,
        message="job accepted",
    )
    _jobs[job_id] = record

    try:
        if engine == "mock":
            output_path = _run_mock(job_path, target_format, background_removed, repair_for_printing, notes)
        elif engine == "triposr":
            output_path = _not_installed(job_path, target_format, "TripoSR adapter not installed yet.")
        elif engine == "trellis":
            output_path = _not_installed(job_path, target_format, "TRELLIS adapter not installed yet.")
        else:
            output_path = _not_installed(job_path, target_format, "VFusion adapter not installed yet.")
        record.status = "complete"
        record.output_path = str(output_path)
        record.message = "complete"
    except Exception as exc:  # pragma: no cover - defensive worker boundary
        record.status = "failed"
        record.message = str(exc)

    return _to_response(record)


@app.get("/jobs/{job_id}", response_model=JobResponse)
def get_job(job_id: str) -> JobResponse:
    record = _jobs.get(job_id)
    if not record:
        record = _load_record_from_disk(job_id)
    if not record:
        raise HTTPException(status_code=404, detail="job not found")
    return _to_response(record)


@app.get("/jobs/{job_id}/download")
def download(job_id: str) -> FileResponse:
    record = _jobs.get(job_id) or _load_record_from_disk(job_id)
    if not record or record.status != "complete" or not record.output_path:
        raise HTTPException(status_code=404, detail="job output not ready")
    path = Path(record.output_path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="job output missing")
    return FileResponse(path, filename=path.name)


def _to_response(record: JobRecord) -> JobResponse:
    return JobResponse(
        job_id=record.job_id,
        engine=record.engine,
        status=record.status,
        output_format=record.output_format,
        message=record.message,
        download_url=f"/jobs/{record.job_id}/download" if record.output_path else None,
    )


def _run_mock(job_path: Path, target_format: str, background_removed: bool, repair_for_printing: bool, notes: str) -> Path:
    # Tiny placeholder OBJ so the iOS app can test upload/download/import before GPU setup.
    ext = target_format.lower().strip(".") or "obj"
    if ext not in {"obj", "glb", "gltf", "ply", "stl"}:
        ext = "obj"
    output = job_path / f"objectforge-mock-output.{ext}"
    if ext == "obj":
        output.write_text(
            "# ObjectForge mock OBJ\n"
            f"# background_removed={background_removed}\n"
            f"# repair_for_printing={repair_for_printing}\n"
            f"# notes={notes}\n"
            "o ObjectForgeMockTriangle\n"
            "v 0 0 0\n"
            "v 1 0 0\n"
            "v 0 1 0\n"
            "f 1 2 3\n",
            encoding="utf-8",
        )
    else:
        output.write_text(
            f"ObjectForge mock {ext.upper()} placeholder. Use OBJ for first import tests.\n",
            encoding="utf-8",
        )
    return output


def _not_installed(job_path: Path, target_format: str, message: str) -> Path:
    output = job_path / "adapter-not-installed.obj"
    output.write_text(
        "# ObjectForge AI worker placeholder\n"
        f"# {message}\n"
        "# Install the selected model adapter on Sidekick/desktop/cloud later.\n"
        "o AdapterNotInstalled\n"
        "v 0 0 0\n"
        "v 1 0 0\n"
        "v 0 1 0\n"
        "f 1 2 3\n",
        encoding="utf-8",
    )
    return output


def _load_record_from_disk(job_id: str) -> JobRecord | None:
    # Minimal disk fallback for mock outputs across reloads.
    job_path = JOB_DIR / job_id
    if not job_path.exists():
        return None
    outputs = list(job_path.glob("objectforge-mock-output.*")) + list(job_path.glob("adapter-not-installed.obj"))
    inputs = list(job_path.glob("input.*"))
    if not outputs or not inputs:
        return None
    return JobRecord(
        job_id=job_id,
        engine="mock",
        status="complete",
        input_path=str(inputs[0]),
        output_path=str(outputs[0]),
        output_format=outputs[0].suffix.lstrip("."),
        message="complete",
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8733)
