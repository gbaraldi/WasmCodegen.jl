#!/usr/bin/env bash
# jl.sh ARGS...: Julia in the probes' environment (env/: WasmCodegen from this repository).
# JL_WRAPPER, if set, is a command that runs it (a memory cap, say:
# JL_WRAPPER="systemd-run --user --scope -p MemoryMax=12G").
set -eu
D="$(cd "$(dirname "$0")" && pwd)"
exec ${JL_WRAPPER:-} env JULIA_NUM_THREADS="${JULIA_NUM_THREADS:-2}" \
    julia --heap-size-hint=8G --startup-file=no --project="$D/env" "$@"
