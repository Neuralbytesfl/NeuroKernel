# NeuroKernel Architecture (EPYC / AVX2 Profile)

## Runtime Layers

1. CLI + DSL parser
- `main.swift`, `Script.swift`, `Executor.swift`
- accepts `.ns` command streams, dispatches into kernel methods

2. Kernel state and orchestration
- `Kernel.swift`
- registries: models, contexts, channels, workers
- limits: workers/rss (manual and `auto`)
- stats: `steps`, `avg_sps`, watchdog states

3. Graph/model subsystem
- `Graph.swift`, `GraphBuilder.swift`
- model creation, serialization, training graph definitions

4. Execution subsystem
- CPU path: `CPUBackend.swift` (portable candidate)
- GPU path: `MPSGraphBackend.swift` (Apple-specific)

5. Concurrency/dataflow
- `Channels.swift` + worker loop in `Kernel.swift`
- bounded channels, blocking semantics, non-blocking variants
- feedback-safe topology supported via worker/channel graph

## Worker/Dataflow Semantics

- Workers are periodic actor-style tasks.
- Source can be constant input or input channel.
- Sink can be print or output channel.
- Backpressure propagates via bounded channels.
- Watchdog classification:
  - `ok`
  - `blocked_input_empty(...)`
  - `blocked_output_full(...)`
  - `stalled(...)`

## Throughput Telemetry

`stats` now exposes:

- per-worker `steps`
- per-worker `avg_sps` (avg steps/sec)
- global `workers_avg_sps`

Use these metrics for run-to-run comparison on EPYC hosts.

## EPYC Tuning Guidance

- Keep channel caps moderate (`8..128`) and tune by queue pressure profile.
- Prefer `limit workers auto` initially; override only after throughput baseline.
- Keep monitor worker lower priority to avoid I/O bottlenecks.
- Compare variants using fixed sleep windows and same seeds.

## Linux Port Delta (for AVX2 host)

The current code is macOS-first. Required Linux work:

1. OS stats abstraction
- replace Darwin task/thread calls with `/proc/self/statm` + `/proc/self/status` parsing.

2. Conditional GPU backend
- disable MPSGraph on Linux build, keep CPU backend active.

3. Package platform targets
- remove/relax `platforms: [.macOS(.v13)]` once Linux-compatible paths exist.

4. Validation
- run stress scripts from this folder and compare `avg_sps`, watchdog profile, rss.
