# NeuroKernel Web UI

Run the API + web console:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r webui/requirements.txt
uvicorn webui.server:app --host 0.0.0.0 --port 8080
```

Open:

- http://localhost:8080

What it supports:

- submit one `.ns` script and stream output in realtime
- submit batch scripts (`---` separator in UI) and stream combined output
- view `Sources/NeuroKernel/MANUAL.md` in-app

API endpoints:

- `POST /api/run`
- `POST /api/run_batch`
- `GET /api/jobs/{job_id}`
- `GET /api/jobs/{job_id}/stream` (SSE)
- `GET /api/manual`

Notes:

- The server executes local scripts through the `neurok` binary built in this repo.
- Build first if needed: `swift build -c release`.
