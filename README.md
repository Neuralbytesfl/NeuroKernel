# NeuroKernel

A narrow neural microkernel in Swift with a DSL-driven runtime for models, contexts, channels, workers, and supervised CSV training.

## Features

- CPU and GPU inference contexts (`cpu` / `gpu`)
- Graph DSL for `dense`, `relu`, `softmax`, and explicit `chain`
- Worker scheduler with routing via bounded channels
- Non-blocking channel operations (`push_nb`, `pop_nb`)
- Supervised training from CSV (`model train ...`) with:
  - checkpointing (`checkpoint_every`, `checkpoint_prefix`)
  - realtime epoch diagnostics (`grad_log_every` -> loss/acc/gradient norms)

## Build

```bash
swift build -c release
```

Binary path:

```bash
./.build/arm64-apple-macosx/release/neurok
```

## Run

Interactive REPL:

```bash
./.build/arm64-apple-macosx/release/neurok
```

Run a script and exit:

```bash
./.build/arm64-apple-macosx/release/neurok runonly <file.ns>
```

Show command reference:

```bash
./.build/arm64-apple-macosx/release/neurok help
```

Full DSL manual lives at:

- `Sources/NeuroKernel/MANUAL.md`

## Web Console (Realtime)

This repo includes a FastAPI + uvicorn web console for remote script submission,
batch execution, and live output streaming.

Setup:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r webui/requirements.txt
uvicorn webui.server:app --host 0.0.0.0 --port 8080
```

Open:

- `http://localhost:8080`

See details:

- `webui/README.md`

## Training Data Format

For `model train <name> csv "<file.csv>" ...`, each CSV row is:

```text
f1,f2,...,fN,label
```

- `N` must match model input size
- `label` is integer class index in `0..<outputSize`

## License

MIT. See [LICENSE](LICENSE).

## Deployment Profiles

- `profiles/amd-epyc-avx2/`: dedicated EPYC/AVX2 architecture runbook, stress template, and environment scripts.
