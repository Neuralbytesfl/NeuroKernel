NeuroKernel (neurok) — Narrow Neural Microkernel (v1)

Core concepts
- MODEL: immutable graph definition (nodes + edges).
- CONTEXT: persistent state bound to a model (last I/O, step, arena, device).
- WORKER: scheduled execution of a context with routing (in/out channels).
- CHANNEL: bounded mailbox for vectors with backpressure.
- DEVICE: cpu or gpu (MPSGraph). CPU uses Accelerate/scalar; GPU uses MPSGraph.

Security / RNG
- secure RNG: SecRandomCopyBytes (cryptographic)
- deterministic RNG: SHA256(counter || seed), useful for reproducible experiments

Graph DSL (file-based)
- Lines, whitespace separated
- Comments start with '#'
- Quotes supported for paths: "path with spaces"
- Vectors: CSV floats 0.1,0.2,0.3
- Line continuation: end a line with `\\` to continue on the next line
- In REPL, `model create ... graph begin` blocks can be pasted across multiple lines; execution happens when `graph end` is entered.

Commands
help
stats
sleep <ms>
quit

`stats` includes per-worker `steps`, `errs`, `watchdog` (`ok` or `stalled(<ms>)`), and `last_err` when failures occur.

Startup monitor
- REPL is quiet by default (no periodic stats lines).
- To enable periodic stats printing, start with env var `NEUROK_MONITOR_MS=<n>` (for example `NEUROK_MONITOR_MS=900 ./neurok`).

# RNG
rng seed_secure
rng seed_deterministic hex <64-hex-bytes>
rng show

# Models
model create <name> graph begin
  input <n>
  dense <name> in <n> out <m>
  relu <name>
  softmax <name>
  chain <node1> <node2> <node3> ...
graph end

model save <name> path "<file.json>"
model load path "<file.json>" [as <name>]
model train <name> csv "<file.csv>" epochs <n> lr <f> [checkpoint_every <n> checkpoint_prefix "<pathPrefix>"] [grad_log_every <n>]

Training from CSV (CPU SGD)
- CSV format: each non-empty, non-comment row is `f1,f2,...,fN,label`.
- `label` is an integer class index in `0..<outputSize`.
- `N` must match model `input`.
- Training expects chain to end with `softmax` and uses softmax cross-entropy + SGD.
- Output includes final `loss` and `acc`.
- Optional checkpointing: when checkpoint options are set together, snapshots are saved as `<pathPrefix>_e<epoch>.json`.
- Optional gradient diagnostics: `grad_log_every <n>` prints periodic gradient L2 norms (`total`, first dense layer, last dense layer).

# Contexts
ctx create <ctxName> model <modelName> device cpu|gpu
ctx run <ctxName> input <csv>
ctx run <ctxName> inchan <chanIn> outchan <chanOut>
ctx save <ctxName> path "<file.json>"
ctx load path "<file.json>" [as <ctxName>]
ctx info <ctxName>
ctx drop <ctxName>

# Channels
chan create <name> cap <n>
chan push <name> <csv>
chan push_nb <name> <csv>
chan pop <name>
chan pop_nb <name>
chan info <name>

Non-blocking channel behavior
- `chan push_nb`: returns immediately; prints `OK ...` when enqueued or `FULL chan <name>` when the buffer is full.
- `chan pop_nb`: returns immediately; prints `CHAN ...` when a value is available or `EMPTY chan <name>` when no value is available.

# Workers (routing workers)
worker spawn <wName> ctx <ctxName> interval_ms <n> priority low|normal|high
  source input <csv>
  source chan <chanIn>
  sink   print
  sink   chan <chanOut>

worker stop <wName>
worker stopall

Worker watchdog behavior
- `watchdog=ok`: worker has a recent successful inference.
- `watchdog=stalled(<ms>)`: time since the last successful inference exceeded the stall threshold.
- Stall threshold is `max(interval_ms * 3, interval_ms + 250)`.
- Workers blocked on empty input channels or repeatedly failing inference will eventually show as stalled.

# Scheduler policies
limit workers <n>
limit rss_mb <n>
sched timeslice_ms <n>

Example
chan create in cap 64
chan create out cap 64

model create m1 graph begin
  input 4
  dense d1 in 4 out 16
  relu r1
  dense d2 in 16 out 3
  softmax s1
  chain d1 r1 d2 s1
graph end

ctx create c1 model m1 device gpu
worker spawn w1 ctx c1 interval_ms 50 priority high source chan in sink chan out
worker spawn w2 ctx c1 interval_ms 200 priority low source input 0.1,0.2,0.3,0.4 sink print

chan push in 1,0,0,0
chan push in 0,1,0,0
chan pop out
