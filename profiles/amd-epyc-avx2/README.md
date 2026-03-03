# AMD EPYC AVX2 Profile

This folder is a dedicated profile for deploying and stress-testing NeuroKernel on high-core AMD EPYC hosts (for example: dual-socket, 128 total logical cores).

## Important Compatibility Note

Current NeuroKernel source uses Apple-specific APIs/frameworks (`Darwin`, `MPSGraph`, macOS process stats), so it does **not** build on Linux as-is.

Use this profile as:

- architecture/runbook reference for EPYC deployment
- stress test configuration source
- migration checklist for Linux CPU-only port

## Folder Contents

- `ARCHITECTURE.md`: runtime architecture map and EPYC tuning notes
- `epyc_v13_stress.ns`: contention stress script (CPU-only DSL)
- `epyc_env.sh`: suggested environment settings for large NUMA hosts
- `run_epyc_stress.sh`: wrapper for building/running stress tests

## Recommended EPYC Defaults (after Linux CPU port)

- `limit workers auto`
- `limit rss_mb auto`
- `sched timeslice_ms 1`
- prefer CPU device (`ctx ... device cpu`)

## Next Porting Targets

1. Replace `OSStats` Darwin calls with Linux `/proc` readers.
2. Gate or remove MPSGraph usage on non-Apple platforms.
3. Keep CPU backend as default path for AVX2 hosts.
4. Add Linux CI profile with stress scripts from this folder.
