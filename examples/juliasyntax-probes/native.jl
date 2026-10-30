# The native output of the items on the corpus, and the time they take:
# ./jl.sh native.jl [<item>,...]   (PROBE_JS=base|reg)
# Writes ref/<js>/<item>.json: per source and mode, the output's length and SHA-256 (and the
# output itself when it is small), and the best of 3 passes over the corpus after a first.
import Base64, JSON, SHA
include("probes.jl")

const SMALL = 1 << 16
jsname = get(ENV, "PROBE_JS", "base")
cases = JSON.parsefile(joinpath(@__DIR__, "corpus.json"))
srcs = [Base64.base64decode(c["src"]) for c in cases]
items = length(ARGS) >= 1 ? split(ARGS[1], ",") : sort(collect(keys(ITEMS)))
dir = joinpath(@__DIR__, "ref", jsname)
mkpath(dir)

function setsrc!(bytes)
    src_resize(Int32(length(bytes)))
    copyto!(SRC, bytes)
end

function call(f, mode)
    try
        return Int(f(Int32(mode)))
    catch e
        return "EXC " * string(nameof(typeof(e)))
    end
end

for item in items
    jsname == "reg" && item == "H2" && continue   # (Meta.parse is Base's parser)
    f = ITEMS[item]
    modes = MODES[item]
    results = Any[]
    for (c, src) in zip(cases, srcs)
        setsrc!(src)
        for m in modes
            r = call(f, m)
            out = r isa Int ? copy(OUT) : UInt8[]
            d = Dict{String,Any}("case" => c["name"], "mode" => m, "len" => length(out),
                                 "sha" => bytes2hex(SHA.sha256(out)))
            r isa String && (d["exc"] = r)
            length(out) <= SMALL && (d["out"] = Base64.base64encode(out))
            push!(results, d)
        end
    end
    times = Float64[]
    for pass in 1:3
        t = 0.0
        for src in srcs
            setsrc!(src)
            for m in modes
                t += @elapsed call(f, m)
            end
        end
        push!(times, t)
    end
    write(joinpath(dir, item * ".json"), JSON.json(Dict("item" => item, "js" => jsname, "julia" => string(VERSION),
                                                        "best_ms" => 1000 * minimum(times), "times_ms" => 1000 .* times,
                                                        "results" => results)))
    nexc = count(r -> haskey(r, "exc"), results)
    println("$item ($jsname): $(length(results)) runs, $nexc exceptions, best of 3: $(round(1000 * minimum(times), digits=1)) ms")
end
