#!/usr/bin/env bash
# speed.sh ITEM NAME "<wasm-opt pipeline>": optimizes out/$NOOPT/base/ITEM.wasm (NOOPT,
# default main+noopt: a build with PROBE_OPT=none PROBE_OPTNAME=noopt) with the pipeline (and the driver's features), as
# out/NAME/base/ITEM.wasm, and runs it on the corpus.
set -u
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
item=$1; name=$2; pipeline=$3
WASMOPT=${WASMOPT:-$(./jl.sh -e 'using WasmCodegen; print(WasmCodegen.Binaryen_jll.wasmopt_path)')}
FEAT="--enable-gc --enable-reference-types --enable-multivalue --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext --enable-exception-handling --enable-tail-call --enable-mutable-globals --closed-world"
mkdir -p "out/$name/base" logs
t0=$(date +%s.%N)
if ! "$WASMOPT" $FEAT $pipeline "out/${NOOPT:-main+noopt}/base/$item.wasm" -o "out/$name/base/$item.wasm" > "logs/wasmopt-$name-$item.log" 2>&1; then
    echo "$item $name: wasm-opt failed: $(tail -3 logs/wasmopt-$name-$item.log | tr '\n' ' ' | cut -c1-300)"; exit 1
fi
t1=$(date +%s.%N)
printf '%s %s: %d bytes, wasm-opt %.1f s :: ' "$item" "$name" "$(stat -c %s "out/$name/base/$item.wasm")" "$(echo "$t1 - $t0" | bc)"
node --experimental-wasm-exnref run.mjs "$name" base "$item" 2>&1 | head -2 | sed 's/{"match"[^}]*}//'
