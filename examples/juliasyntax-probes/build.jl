# Compile the entry points of items: ./jl.sh build.jl <label> <item>[,<item>...] [unsafe]
# (PROBE_JS=base|reg selects the JuliaSyntax). Writes out/<label>/<js>/<item>[.unsafe].wasm
# and a .json of the compilation: size, time, functions, and the error if it fails.
# `unsafe` compiles with `trim = :unsafe, on_unsupported = :trap`: what cannot be compiled
# traps where it is, and is listed.
using WasmCodegen
import JSON
include("probes.jl")

envname = ARGS[1]
unsafe = length(ARGS) >= 3 && ARGS[3] == "unsafe"
jsname = get(ENV, "PROBE_JS", "base")
# PROBE_HOST=wasi: Config(host = :wasi) (PR #31), the module's files and environment over WASI
host = Symbol(get(ENV, "PROBE_HOST", "js"))
# PROBE_OPT="<wasm-opt options>" (in place of the default -O3), PROBE_OPTNAME a name for them
opt = get(ENV, "PROBE_OPT", "")
dir = joinpath(@__DIR__, "out", envname * (get(ENV, "PROBE_PATCHES", "0") == "1" ? "+patches" : "") *
                                (host === :wasi ? "+wasi" : "") *
                                (isempty(opt) ? "" : "+" * get(ENV, "PROBE_OPTNAME", "opt")), jsname)
mkpath(dir)
# PROBE_PATCHES=1: with the project patches of patches/ (Config(extra_patches), PR #27)
patched = get(ENV, "PROBE_PATCHES", "0") == "1"
kws = patched ? (; extra_patches = [joinpath(@__DIR__, "patches", "juliasyntax-wasm.jl")],
                   patch_bindings = Pair{Symbol,Any}[:JSMod => JS]) : (;)
host === :wasi && (kws = (; kws..., host))
isempty(opt) || (kws = (; kws..., optimize = opt == "none" ? nothing : Cmd(String.(split(opt)))))
config = unsafe ? WasmCodegen.Config(; trim = :unsafe, on_unsupported = :trap, kws...) : WasmCodegen.Config(; kws...)

for item in split(ARGS[2], ",")
    stem = joinpath(dir, item * (unsafe ? ".unsafe" : ""))
    stats = Dict{String,Any}("env" => envname, "js" => jsname, "item" => item, "unsafe" => unsafe,
                             "julia" => string(VERSION), "wasmcodegen" => pkgdir(WasmCodegen))
    t0 = time()
    try
        c = WasmCodegen.compile([WasmCodegen.Entry(f, at) for (f, at) in entries(item)]; config)
        stats["seconds"] = time() - t0
        write(stem * ".wasm", c.bytes)
        stats["ok"] = true
        stats["bytes"] = length(c.bytes)
        stats["functions"] = length(c.cgm.funcs)
        stats["objects"] = length(c.cgm.image.globals)
        stats["traps"] = [sprint(showerror, err) * "\n    in " * string(mi) for (mi, err) in c.cgm.diagnostics]
        println("$item ($jsname, $envname$(unsafe ? ", unsafe" : "")): $(length(c.bytes)) bytes, ",
                "$(stats["functions"]) functions, $(length(stats["traps"])) traps, $(round(stats["seconds"], digits=1)) s")
    catch e
        stats["seconds"] = time() - t0
        stats["ok"] = false
        stats["error"] = sprint(showerror, e)
        stats["error_type"] = string(typeof(e))
        rm(stem * ".wasm"; force = true)
        println("$item ($jsname, $envname$(unsafe ? ", unsafe" : "")): FAILED after $(round(stats["seconds"], digits=1)) s: ",
                first(stats["error"], 3000))
    end
write(stem * ".json", JSON.json(stats, 2))
end
