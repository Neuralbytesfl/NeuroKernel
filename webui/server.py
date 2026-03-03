#!/usr/bin/env python3
import asyncio
import json
import os
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parents[1]
MANUAL_PATH = ROOT / "Sources" / "NeuroKernel" / "MANUAL.md"
RUN_DIR = ROOT / "webui" / "runs"
RUN_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_BIN = ROOT / ".build" / "arm64-apple-macosx" / "release" / "neurok"
FALLBACK_BIN = ROOT / ".build" / "release" / "neurok"

app = FastAPI(title="NeuroKernel Web Runner", version="1.0.0")
app.mount("/static", StaticFiles(directory=str(ROOT / "webui" / "static")), name="static")


class RunRequest(BaseModel):
    script: str = Field(min_length=1)
    mode: str = Field(default="runonly")
    dataset: Optional[str] = None
    dataset_name: str = Field(default="dataset.csv")


class BatchRequest(BaseModel):
    scripts: List[str] = Field(min_length=1)
    mode: str = Field(default="runonly")
    dataset: Optional[str] = None
    dataset_name: str = Field(default="dataset.csv")


@dataclass
class Job:
    id: str
    mode: str
    created_at: float
    scripts_total: int
    status: str = "queued"
    exit_code: Optional[int] = None
    lines: List[str] = field(default_factory=list)
    done: asyncio.Event = field(default_factory=asyncio.Event)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def add_line(self, line: str) -> None:
        async with self.lock:
            self.lines.append(line)


jobs: Dict[str, Job] = {}


def resolve_binary() -> Path:
    if DEFAULT_BIN.exists():
        return DEFAULT_BIN
    if FALLBACK_BIN.exists():
        return FALLBACK_BIN
    raise FileNotFoundError("neurok binary not found. Build with: swift build -c release")


async def run_one_script(
    job: Job,
    binary: Path,
    script_text: str,
    index: int,
    total: int,
    dataset_text: Optional[str] = None,
    dataset_name: str = "dataset.csv",
) -> int:
    needs_dataset = "{{DATASET_PATH}}" in script_text
    has_dataset = dataset_text is not None and dataset_text.strip() != ""

    if needs_dataset and not has_dataset:
        await job.add_line("[error] script uses {{DATASET_PATH}} but dataset textarea is empty")
        return 2

    if has_dataset:
        ds_tmp = tempfile.NamedTemporaryFile(
            mode="w",
            suffix=f"_{os.path.basename(dataset_name)}",
            prefix=f"job_{job.id}_dataset_",
            dir=RUN_DIR,
            delete=False,
        )
        ds_tmp.write(dataset_text.strip() + "\n")
        ds_tmp.flush()
        ds_tmp.close()
        dataset_path = ds_tmp.name
        # Optional convenience token for scripts.
        script_text = script_text.replace("{{DATASET_PATH}}", dataset_path)
        await job.add_line(f"[batch {index}/{total}] dataset={os.path.basename(dataset_path)}")

    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".ns", prefix=f"job_{job.id}_", dir=RUN_DIR, delete=False)
    tmp.write(script_text)
    tmp.flush()
    tmp.close()
    script_path = tmp.name

    await job.add_line(f"[batch {index}/{total}] script={os.path.basename(script_path)}")

    proc = await asyncio.create_subprocess_exec(
        str(binary),
        job.mode,
        script_path,
        cwd=str(ROOT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    assert proc.stdout is not None
    while True:
        raw = await proc.stdout.readline()
        if not raw:
            break
        line = raw.decode(errors="replace").rstrip("\n")
        await job.add_line(line)

    code = await proc.wait()
    await job.add_line(f"[batch {index}/{total}] exit={code}")
    return code


async def execute_job(job: Job, scripts: List[str], dataset_text: Optional[str], dataset_name: str) -> None:
    try:
        binary = resolve_binary()
    except FileNotFoundError as e:
        job.status = "failed"
        job.exit_code = 127
        await job.add_line(str(e))
        job.done.set()
        return

    job.status = "running"
    await job.add_line(f"job={job.id} mode={job.mode} scripts={len(scripts)}")

    final_code = 0
    for i, script in enumerate(scripts, start=1):
        code = await run_one_script(
            job,
            binary,
            script,
            i,
            len(scripts),
            dataset_text=dataset_text,
            dataset_name=dataset_name,
        )
        if code != 0:
            final_code = code
            break

    job.exit_code = final_code
    job.status = "done" if final_code == 0 else "failed"
    await job.add_line(f"job={job.id} status={job.status} exit={final_code}")
    job.done.set()


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(ROOT / "webui" / "static" / "index.html")


@app.get("/api/manual")
async def manual() -> dict:
    if not MANUAL_PATH.exists():
        raise HTTPException(status_code=404, detail="MANUAL.md not found")
    return {"manual": MANUAL_PATH.read_text(encoding="utf-8")}


@app.post("/api/run")
async def run_script(req: RunRequest) -> dict:
    if req.mode not in ("run", "runonly"):
        raise HTTPException(status_code=400, detail="mode must be run or runonly")

    job_id = uuid.uuid4().hex[:12]
    job = Job(id=job_id, mode=req.mode, created_at=time.time(), scripts_total=1)
    jobs[job_id] = job
    asyncio.create_task(execute_job(job, [req.script], req.dataset, req.dataset_name))
    return {"job_id": job_id}


@app.post("/api/run_batch")
async def run_batch(req: BatchRequest) -> dict:
    if req.mode not in ("run", "runonly"):
        raise HTTPException(status_code=400, detail="mode must be run or runonly")

    scripts = [s for s in req.scripts if s.strip()]
    if not scripts:
        raise HTTPException(status_code=400, detail="scripts list is empty")

    job_id = uuid.uuid4().hex[:12]
    job = Job(id=job_id, mode=req.mode, created_at=time.time(), scripts_total=len(scripts))
    jobs[job_id] = job
    asyncio.create_task(execute_job(job, scripts, req.dataset, req.dataset_name))
    return {"job_id": job_id, "count": len(scripts)}


@app.get("/api/jobs/{job_id}")
async def job_status(job_id: str) -> dict:
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="job not found")
    return {
        "job_id": job.id,
        "status": job.status,
        "exit_code": job.exit_code,
        "scripts_total": job.scripts_total,
        "lines": len(job.lines),
    }


@app.get("/api/jobs/{job_id}/stream")
async def job_stream(job_id: str) -> StreamingResponse:
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="job not found")

    async def event_stream():
        cursor = 0
        while True:
            async with job.lock:
                if cursor < len(job.lines):
                    chunk = job.lines[cursor:]
                    cursor = len(job.lines)
                else:
                    chunk = []
                done = job.done.is_set()

            for line in chunk:
                payload = json.dumps({"line": line})
                yield f"data: {payload}\n\n"

            if done and cursor >= len(job.lines):
                end_payload = json.dumps({"done": True, "status": job.status, "exit_code": job.exit_code})
                yield f"data: {end_payload}\n\n"
                break

            await asyncio.sleep(0.15)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("webui.server:app", host="0.0.0.0", port=8080, reload=False)
