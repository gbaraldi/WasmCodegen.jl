# The native profile of an item over the corpus: ./jl.sh profnative.jl <item> [passes]
# (PROBE_JS=base|reg): the functions by self time (samples where they are the innermost frame).
import Base64, JSON, Profile
include("probes.jl")

item = ARGS[1]
passes = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
f = ITEMS[item]
srcs = [Base64.base64decode(c["src"]) for c in JSON.parsefile(joinpath(@__DIR__, "corpus.json"))]
function run_passes(n)
    t = 0.0
    for _ in 1:n, src in srcs
        src_resize(Int32(length(src))); copyto!(SRC, src)
        for m in MODES[item]
            t += @elapsed f(Int32(m))
        end
    end
    return t
end
run_passes(1)
Profile.init(n = 10^7, delay = 0.0005)
t = Profile.@profile run_passes(passes)
println("$item native: $(round(1000 * t / passes, digits=1)) ms per pass in the item's calls")
# self time: each sample's innermost Julia frame (an inlined function counts as itself), and
# the innermost frame that is not inlined (what a Wasm function would hold)
data, ldict = Profile.retrieve()
data = Profile.has_meta(data) ? Profile.strip_meta(data) : data
selfinl = Dict{String,Int}(); selfnoinl = Dict{String,Int}(); nsamples = 0
fr(sf) = string(sf.func, " @ ", basename(string(sf.file)), ":", sf.line)
let first_ip = true
    global nsamples
    for ip in data
        if ip == 0
            first_ip = true
            continue
        end
        first_ip || continue
        frames = filter(sf -> !sf.from_c, get(ldict, ip, Base.StackTraces.StackFrame[]))
        isempty(frames) && continue
        first_ip = false
        nsamples += 1
        selfinl[fr(frames[1])] = get(selfinl, fr(frames[1]), 0) + 1
        k = findfirst(sf -> !sf.inlined, frames)
        k === nothing || (selfnoinl[string(frames[k].func)] = get(selfnoinl, string(frames[k].func), 0) + 1)
    end
end
println("\nself, innermost frame (inlined functions as themselves), $nsamples samples:")
for (k, v) in first(sort(collect(selfinl), by = last, rev = true), 25)
    println(lpad(round(100v / nsamples, digits = 1), 6), "%  ", first(k, 150))
end
println("\nself, innermost non-inlined function (as the Wasm functions are):")
for (k, v) in first(sort(collect(selfnoinl), by = last, rev = true), 25)
    println(lpad(round(100v / nsamples, digits = 1), 6), "%  ", first(k, 150))
end
