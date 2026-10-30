#!/usr/bin/env bash
# queue.sh JOB...: one job after another. A JOB is `ref:<js>` (the native reference) or
# `<label>[+patches][+wasi]:<js>:<item>,<item>...[:unsafe]` (build the items in one session,
# then run each module that compiled in Node). Logs to logs/.
set -u
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D"
mkdir -p logs
for job in "$@"; do
    IFS=: read -r env js items mode <<< "$job"
    if [ "$env" = ref ]; then
        PROBE_JS=$js ./jl.sh native.jl ${items:-} 2>&1 | tee -a "logs/native-$js.log"
        continue
    fi
    log="logs/build-$env-$js${mode:+-$mode}.log"
    # (`+patches`: with the project patches of patches/)
    # (`+wasi`: built with Config(host = :wasi))
    base=${env%%+*}
    patches=0; [[ "$env" == *+patches* ]] && patches=1
    host=js; [[ "$env" == *+wasi* ]] && host=wasi
    PROBE_JS=$js PROBE_PATCHES=$patches PROBE_HOST=$host ./jl.sh build.jl "$base" "$items" ${mode:-} >> "$log" 2>&1
    grep -E "^(A|B|C|D|E|F|G|H|H2|I) \(" "$log" | tail -n "$(tr ',' '\n' <<< "$items" | wc -l)" | cut -c1-400
    for item in ${items//,/ }; do
        stem=$item${mode:+.$mode}
        [ -f "out/$env/$js/$stem.wasm" ] || continue
        node --experimental-wasm-exnref run.mjs "$env" "$js" "$item" ${mode:-} 2>&1 | tee -a "logs/run-$env-$js.log"
    done
done
