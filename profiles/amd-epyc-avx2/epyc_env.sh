#!/usr/bin/env bash
set -euo pipefail

# Suggested runtime env for dual-socket EPYC stress runs.
# Apply only after Linux-compatible NeuroKernel build exists.

export OMP_NUM_THREADS=128
export OMP_PROC_BIND=spread
export OMP_PLACES=cores

# Keep allocator behavior deterministic-ish for profiling.
export MALLOC_ARENA_MAX=4

# Optional: if using OpenBLAS in future CPU backend tuning.
export OPENBLAS_NUM_THREADS=1

printf 'EPYC env loaded\n'
printf 'OMP_NUM_THREADS=%s\n' "$OMP_NUM_THREADS"
printf 'MALLOC_ARENA_MAX=%s\n' "$MALLOC_ARENA_MAX"
