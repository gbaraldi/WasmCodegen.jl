# How much of JuliaSyntax compiles

Probes of JuliaSyntax compiled to WebAssembly, item by item, each compared with the native
output of the same function on a corpus. Each item is one entry point of `probes.jl`
(`item_A` … `item_I`); a module is the item plus the three functions that pass bytes
(`src_resize`, `src_set4`, `out_word`). Only numbers cross the boundary.

| Item | Entry | Modes |
|---|---|---|
| A | `tokenize` / `Tokenize.Lexer` | 1 `tokenize`, 2 the raw lexer |
| B | `ParseStream` + `parse!`, the output nodes and diagnostics (the example's output) | rule 1 `:all`, 2 `:statement`, 3 `:atom` |
| C | `build_tree(GreenNode, stream)` | |
| D | `build_tree(SyntaxNode, stream)`, leaf values included | |
| E | `parseall(Expr, …)` / `parsestmt(Expr, …)`, `ignore_errors = true` | 1 `parseall`, 2 `parsestmt` |
| F | `showerror` of the `ParseError` of `parseall(Expr, …)` | 1 plain, 2 `:color => true` |
| G | `parseall(Expr, …; filename, first_line = 7, version)` | version 1 `VERSION`, 2 v1.0, 3 v1.6, 4 v1.10 |
| H | `core_parser_hook(code, filename, 1, 0, options)`, as `Core._parse` | 1 `:all`, 2 `:statement`, 3 `:atom` |
| H2 | `Meta.parseall` / `Meta.parse(…; raise = false)`, through `Core._parse` | |
| I | round trips: the source from the green tree's leaves; `string` of each statement, parsed again, `==` | |
| P | `parse!` alone (the parser's speed, without writing an output) | |

`Expr`s and leaf values are written exactly (types tagged, floats by their bits), so equal
outputs mean `==` values of the same types.

## Running

`jl.sh` runs Julia in `env/`: WasmCodegen from this repository, and the registered
JuliaSyntax.jl, which `PROBE_JS=reg` probes instead of `Base.JuliaSyntax`. Run one job at a time: a compilation takes several GB.

```
./jl.sh -e 'using Pkg; Pkg.instantiate()'
./jl.sh corpus.jl                          # corpus.json: 30 files of the installation, 47 snippets
PROBE_JS=base ./jl.sh native.jl            # ref/base/<item>.json: native outputs and times
PROBE_JS=base ./jl.sh build.jl main A,B,C  # out/main/base/<item>.wasm (+ .json: size, time, errors)
PROBE_JS=base ./jl.sh build.jl main D unsafe   # trim = :unsafe: what doesn't compile traps where it is
node --experimental-wasm-exnref run.mjs main base A   # results/main/base/A.json
node --experimental-wasm-exnref run.mjs main base D unsafe
node summarize.mjs                         # the matrix
node blockers.mjs main base                # the distinct unsupported constructs, by item
```

`main` is a label (the directory of the outputs): name builds after the branch they were
made with.

Options of `build.jl` (environment variables): `PROBE_PATCHES=1` compiles with the project
patches of `patches/juliasyntax-wasm.jl` (`Config(extra_patches)`, which need PR #27: not on
`main`), `PROBE_HOST=wasi` with `Config(host = :wasi)`, `PROBE_OPT="<wasm-opt options>"` (or
`none`) in place of `-O3`, named by `PROBE_OPTNAME`. Each writes to `out/<label>+patches`, `+wasi`,
`+<name>`. `queue.sh` runs jobs `<label>[+patches][+wasi]:<js>:<items>[:unsafe]` one after another.
`patchcheck.jl` shows what the patches change natively.

Speed: `speed.sh ITEM NAME "<pipeline>"` optimizes an unoptimized build (`PROBE_OPT=none
PROBE_OPTNAME=noopt ./jl.sh build.jl main P`: `out/main+noopt`) with a `wasm-opt` pipeline
and runs it; `prof.mjs` (under `node
--cpu-prof`, on a build with `-g`) and `profnative.jl` give the functions by self time.

Times: Node, best of 3 passes over the corpus after a first pass that checks the output;
native, best of 3 after a first pass. Both time only the item's call.
