#!/usr/bin/env python3
import asyncio
import json
import os
import math
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


def _total_memory_bytes() -> int:
    # AUTO-IMPROVEMENT: resource-aware limits should adapt to host RAM without extra deps.
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
        if isinstance(pages, int) and isinstance(page_size, int) and pages > 0 and page_size > 0:
            return pages * page_size
    except (ValueError, OSError, AttributeError):
        pass
    return 8 * 1024 * 1024 * 1024


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        v = int(raw)
        return v if v > 0 else default
    except ValueError:
        return default


CPU_COUNT = max(1, os.cpu_count() or 1)
MEM_BYTES = _total_memory_bytes()
MEM_GB = max(1, int(MEM_BYTES // (1024 ** 3)))

# AUTO-IMPROVEMENT: hard guardrails against batch abuse with host-aware defaults + env overrides.
MAX_BATCH_SCRIPTS = _env_int("NEUROK_WEB_MAX_BATCH_SCRIPTS", max(4, min(128, CPU_COUNT * 2)))
MAX_SCRIPT_BYTES = _env_int("NEUROK_WEB_MAX_SCRIPT_BYTES", 256 * 1024)
MAX_BATCH_TOTAL_BYTES = _env_int(
    "NEUROK_WEB_MAX_BATCH_TOTAL_BYTES",
    max(512 * 1024, min(32 * 1024 * 1024, MEM_GB * 2 * 1024 * 1024)),
)
MAX_DATASET_BYTES = _env_int(
    "NEUROK_WEB_MAX_DATASET_BYTES",
    max(512 * 1024, min(128 * 1024 * 1024, MEM_GB * 4 * 1024 * 1024)),
)
MAX_ACTIVE_JOBS = _env_int("NEUROK_WEB_MAX_ACTIVE_JOBS", max(2, min(64, int(math.sqrt(CPU_COUNT)) * 4)))
MAX_JOB_LOG_LINES = _env_int("NEUROK_WEB_MAX_JOB_LOG_LINES", max(4000, min(200000, MEM_GB * 8000)))

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
    dropped_lines: int = 0
    done: asyncio.Event = field(default_factory=asyncio.Event)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def add_line(self, line: str) -> None:
        async with self.lock:
            self.lines.append(line)
            if len(self.lines) > MAX_JOB_LOG_LINES:
                overflow = len(self.lines) - MAX_JOB_LOG_LINES
                del self.lines[:overflow]
                self.dropped_lines += overflow


jobs: Dict[str, Job] = {}


def _active_jobs_count() -> int:
    return sum(1 for j in jobs.values() if not j.done.is_set())


def _reject_if_overloaded() -> None:
    if _active_jobs_count() >= MAX_ACTIVE_JOBS:
        raise HTTPException(
            status_code=429,
            detail=f"server busy: active_jobs limit reached ({MAX_ACTIVE_JOBS})",
        )


def _validate_dataset(dataset: Optional[str]) -> None:
    if dataset is None:
        return
    size = len(dataset.encode("utf-8"))
    if size > MAX_DATASET_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"dataset too large: {size} bytes > limit {MAX_DATASET_BYTES}",
        )


def _validate_scripts(scripts: List[str]) -> None:
    if len(scripts) > MAX_BATCH_SCRIPTS:
        raise HTTPException(
            status_code=413,
            detail=f"too many scripts: {len(scripts)} > limit {MAX_BATCH_SCRIPTS}",
        )
    total = 0
    for idx, script in enumerate(scripts, start=1):
        size = len(script.encode("utf-8"))
        if size > MAX_SCRIPT_BYTES:
            raise HTTPException(
                status_code=413,
                detail=f"script #{idx} too large: {size} bytes > limit {MAX_SCRIPT_BYTES}",
            )
        total += size
    if total > MAX_BATCH_TOTAL_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"batch payload too large: {total} bytes > limit {MAX_BATCH_TOTAL_BYTES}",
        )


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
    _reject_if_overloaded()
    _validate_dataset(req.dataset)
    _validate_scripts([req.script])

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
    _reject_if_overloaded()
    _validate_dataset(req.dataset)
    _validate_scripts(scripts)

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
        "dropped_lines": job.dropped_lines,
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
