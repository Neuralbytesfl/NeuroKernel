#!/usr/bin/env python3
"""
signal_train.py

Generates a synthetic time-series "signal" dataset, writes it to CSV,
auto-writes a NeuroKernel .ns script that trains from that CSV,
then runs the neurok engine and streams output in realtime.

Dataset:
- Binary classification: "is the last sample above the window mean + k*std?"
- Features: window of N floats (e.g., 32 samples)
- Labels: 0 or 1 (2-class softmax)

CSV format expected by your new Swift command:
- Each row: <f0>,<f1>,...,<fN-1>,<label_int>
  where label_int in {0,1}
"""

import argparse
import math
import os
import random
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import List, Tuple

# --------------------------
# ANSI colors (optional)
# --------------------------
class C:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"
    BLUE = "\033[94m"
    MAGENTA = "\033[95m"

# --------------------------
# Signal generation
# --------------------------
def gen_signal(length: int, seed: int, noise: float, drift: float, burst_p: float) -> List[float]:
    """
    Generate a 1D signal:
    - base: mixture of 2 sines
    - add drift (random walk-ish)
    - add gaussian-ish noise (approx via sum of uniforms)
    - occasional bursts
    """
    rng = random.Random(seed)
    x = []
    d = 0.0
    for t in range(length):
        # base periodic
        base = 0.7 * math.sin(2.0 * math.pi * t / 50.0) + 0.3 * math.sin(2.0 * math.pi * t / 13.0)
        # drift
        d += (rng.random() * 2.0 - 1.0) * drift
        # pseudo-gaussian noise
        n = 0.0
        for _ in range(6):
            n += (rng.random() * 2.0 - 1.0)
        n = (n / 6.0) * noise

        v = base + d + n

        # bursts
        if rng.random() < burst_p:
            v += (rng.random() * 2.0 - 1.0) * 3.0

        x.append(v)
    return x

def window_stats(w: List[float]) -> Tuple[float, float]:
    m = sum(w) / float(len(w))
    var = sum((v - m) ** 2 for v in w) / float(len(w))
    s = math.sqrt(var + 1e-12)
    return m, s

def make_dataset(
    series: List[float],
    window: int,
    k: float,
    stride: int,
    max_rows: int,
    seed: int,
) -> List[Tuple[List[float], int]]:
    """
    Build supervised rows from a series:
    - features: last `window` samples
    - label: 1 if last sample > mean + k*std else 0
    """
    rng = random.Random(seed)
    rows: List[Tuple[List[float], int]] = []
    for i in range(window, len(series), stride):
        w = series[i - window : i]
        m, s = window_stats(w)
        last = w[-1]
        label = 1 if last > (m + k * s) else 0
        rows.append((w, label))
        if len(rows) >= max_rows:
            break

    # Shuffle for better SGD
    rng.shuffle(rows)
    return rows

def write_csv(path: str, rows: List[Tuple[List[float], int]]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for feats, y in rows:
            # Use compact decimals; NeuroKernel parser accepts plain floats
            line = ",".join(f"{v:.6f}" for v in feats) + f",{y}\n"
            f.write(line)

# --------------------------
# NeuroKernel .ns writer
# --------------------------
def make_ns_script(
    csv_path: str,
    out_ns_path: str,
    model_out_path: str,
    seed_hex: str,
    input_size: int,
    hidden: List[int],
    epochs: int,
    lr: float,
    device: str,
    grad_log_every: int,
) -> str:
    """
    Creates a training + quick inference sanity check program.

    NOTE: Training currently CPU-only per your note. We still allow device selection
          for the post-train ctx runs; if GPU is used, your kernel said it invalidates
          GPU contexts so they rebuild with trained weights.
    """
    if device not in ("cpu", "gpu"):
        device = "cpu"

    # Build graph lines: dense + relu for all hidden, then dense + softmax output (2 classes)
    lines: List[str] = []
    lines.append(f"rng seed_deterministic hex {seed_hex}")
    lines.append("rng show")
    lines.append("")
    lines.append("model create sig_m graph begin")
    lines.append(f"  input {input_size}")

    chain_tokens: List[str] = []
    prev = input_size
    for i, h in enumerate(hidden):
        d = f"d{i}"
        r = f"r{i}"
        lines.append(f"  dense {d} in {prev} out {h}")
        lines.append(f"  relu {r}")
        chain_tokens.extend([d, r])
        prev = h

    # output 2 (binary)
    lines.append(f"  dense dout in {prev} out 2")
    lines.append("  softmax sout")
    chain_tokens.extend(["dout", "sout"])
    lines.append("  chain " + " ".join(chain_tokens))
    lines.append("graph end")
    lines.append("")
    lines.append(
        f'model train sig_m csv "{csv_path}" epochs {epochs} lr {lr} grad_log_every {grad_log_every}'
    )
    # AUTO-IMPROVEMENT: persist trained weights so learning is not lost after process exit.
    lines.append(f'model save sig_m path "{model_out_path}"')
    lines.append("")
    lines.append(f"ctx create sig_ctx model sig_m device {device}")

    # A few deterministic "probe" inputs to see output changes
    # We'll just run 4 example windows. If you want, you can replace these later with real windows.
    # Here we use simple ramps.
    def ramp(n: int, a: float, b: float) -> str:
        if n <= 1:
            return f"{a:.6f}"
        return ",".join(f"{(a + (b - a) * (i / (n - 1))):.6f}" for i in range(n))

    lines.append(f"ctx run sig_ctx input {ramp(input_size, -0.5, 0.5)}")
    lines.append(f"ctx run sig_ctx input {ramp(input_size, 0.0, 1.0)}")
    lines.append(f"ctx run sig_ctx input {ramp(input_size, 1.0, 0.0)}")
    lines.append(f"ctx run sig_ctx input {ramp(input_size, -1.0, -0.2)}")

    script = "\n".join(lines) + "\n"
    os.makedirs(os.path.dirname(out_ns_path) or ".", exist_ok=True)
    with open(out_ns_path, "w", encoding="utf-8") as f:
        f.write(script)
    return script

# --------------------------
# Runner (realtime output)
# --------------------------
def run_neurok(neurok_bin: str, ns_path: str) -> int:
    proc = subprocess.Popen(
        [neurok_bin, "runonly", ns_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.rstrip("\n")
        # colorize a bit
        if line.startswith("OK TRAIN"):
            print(C.GREEN + C.BOLD + line + C.RESET)
        elif line.startswith("GRAD "):
            print(C.MAGENTA + line + C.RESET)
        elif line.startswith("OK "):
            print(C.GREEN + line + C.RESET)
        elif line.startswith("WARN") or "error" in line.lower():
            print(C.YELLOW + line + C.RESET)
        elif line.startswith("OUT") or line.startswith("CHAN"):
            print(C.CYAN + line + C.RESET)
        else:
            print(line)

    return proc.wait()

# --------------------------
# CLI
# --------------------------
@dataclass
class Args:
    neurok: str
    out_dir: str
    seed: int
    signal_len: int
    window: int
    stride: int
    rows: int
    noise: float
    drift: float
    burst_p: float
    k: float
    hidden: str
    epochs: int
    lr: float
    grad_log_every: int
    device: str

def parse_args() -> Args:
    p = argparse.ArgumentParser()
    p.add_argument("--neurok", default="./.build/arm64-apple-macosx/release/neurok",
                   help="Path to neurok binary")
    p.add_argument("--out-dir", default="examples/signal_train",
                   help="Output directory for CSV + .ns")
    p.add_argument("--seed", type=int, default=123,
                   help="Random seed")
    p.add_argument("--signal-len", type=int, default=20000,
                   help="Length of generated raw signal")
    p.add_argument("--window", type=int, default=32,
                   help="Feature window size (input_size)")
    p.add_argument("--stride", type=int, default=1,
                   help="Stride between windows")
    p.add_argument("--rows", type=int, default=4000,
                   help="Max CSV rows")
    p.add_argument("--noise", type=float, default=0.25,
                   help="Noise level")
    p.add_argument("--drift", type=float, default=0.002,
                   help="Drift per step")
    p.add_argument("--burst-p", type=float, default=0.01,
                   help="Burst probability per step")
    p.add_argument("--k", type=float, default=1.0,
                   help="Threshold factor: mean + k*std")
    p.add_argument("--hidden", default="64,64,32",
                   help='Hidden layer sizes CSV, e.g. "64,64,32"')
    p.add_argument("--epochs", type=int, default=2000,
                   help="Training epochs")
    p.add_argument("--lr", type=float, default=0.05,
                   help="Learning rate")
    p.add_argument("--grad-log-every", type=int, default=100,
                   help="Print training gradient diagnostics every N epochs (realtime)")
    p.add_argument("--device", default="cpu", choices=["cpu", "gpu"],
                   help="Device for ctx runs (training is currently CPU-side)")
    a = p.parse_args()
    return Args(**vars(a))

def main() -> None:
    args = parse_args()

    if not os.path.exists(args.neurok):
        # convenience fallback for users passing ./.build/release/neurok
        fallback = "./.build/arm64-apple-macosx/release/neurok"
        if args.neurok == "./.build/release/neurok" and os.path.exists(fallback):
            args.neurok = fallback
            print(C.YELLOW + f"Using fallback neurok path: {args.neurok}" + C.RESET)
        else:
            print(C.RED + f"neurok not found: {args.neurok}" + C.RESET)
            print(C.YELLOW + "Build first: swift build -c release" + C.RESET)
            sys.exit(2)

    # Parse hidden layers
    hidden: List[int] = []
    try:
        hidden = [int(x.strip()) for x in args.hidden.split(",") if x.strip()]
        if not hidden:
            raise ValueError("empty hidden")
        if any(h < 2 for h in hidden):
            raise ValueError("hidden layers must be >=2")
    except Exception as e:
        print(C.RED + f"Bad --hidden '{args.hidden}': {e}" + C.RESET)
        sys.exit(2)

    os.makedirs(args.out_dir, exist_ok=True)
    csv_path = os.path.join(args.out_dir, "signal_dataset.csv")
    ns_path = os.path.join(args.out_dir, "signal_train.ns")
    model_json_path = os.path.join(args.out_dir, "signal_model_trained.json")

    print(C.MAGENTA + C.BOLD + "\n[1] Generating signal..." + C.RESET)
    series = gen_signal(
        length=args.signal_len,
        seed=args.seed,
        noise=args.noise,
        drift=args.drift,
        burst_p=args.burst_p,
    )

    print(C.MAGENTA + C.BOLD + "[2] Building dataset..." + C.RESET)
    rows = make_dataset(
        series=series,
        window=args.window,
        k=args.k,
        stride=args.stride,
        max_rows=args.rows,
        seed=args.seed + 999,
    )

    # quick class balance
    ones = sum(y for _, y in rows)
    zeros = len(rows) - ones
    print(C.BLUE + f"Rows: {len(rows)} | class0={zeros} class1={ones}" + C.RESET)

    print(C.MAGENTA + C.BOLD + f"[3] Writing CSV: {csv_path}" + C.RESET)
    write_csv(csv_path, rows)

    # deterministic seed hex (64 hex chars)
    # You can change this, but keep length consistent.
    seed_hex = f"{args.seed:064x}"[-64:]

    print(C.MAGENTA + C.BOLD + f"[4] Writing .ns: {ns_path}" + C.RESET)
    make_ns_script(
        csv_path=csv_path,
        out_ns_path=ns_path,
        model_out_path=model_json_path,
        seed_hex=seed_hex,
        input_size=args.window,
        hidden=hidden,
        epochs=args.epochs,
        lr=args.lr,
        device=args.device,
        grad_log_every=args.grad_log_every,
    )

    print(C.MAGENTA + C.BOLD + "\n[5] Running NeuroKernel (realtime output)..." + C.RESET)
    rc = run_neurok(args.neurok, ns_path)
    if rc == 0:
        if os.path.exists(model_json_path):
            sz = os.path.getsize(model_json_path)
            print(C.GREEN + f"Saved trained model: {model_json_path} ({sz} bytes)" + C.RESET)
        else:
            print(C.YELLOW + f"WARNING: expected trained model not found: {model_json_path}" + C.RESET)
        print(C.GREEN + C.BOLD + "\nDONE (rc=0)\n" + C.RESET)
    else:
        print(C.RED + C.BOLD + f"\nFAILED (rc={rc})\n" + C.RESET)
    sys.exit(rc)

if __name__ == "__main__":
    main()
