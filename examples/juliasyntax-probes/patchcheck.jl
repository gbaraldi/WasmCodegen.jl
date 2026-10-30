# What the project patches (patches/juliasyntax-wasm.jl) change natively: the items run with
# the patches applied in this session, compared with ref/<js>/ (made without them).
# ./jl.sh patchcheck.jl [<item>,...]   (PROBE_JS=base|reg)
import Base64, JSON, SHA
include("probes.jl")

module PatchSandbox
const JSMod = Main.JS
include(joinpath(@__DIR__, "patches", "juliasyntax-wasm.jl"))
end

jsname = get(ENV, "PROBE_JS", "base")
cases = JSON.parsefile(joinpath(@__DIR__, "corpus.json"))
items = length(ARGS) >= 1 ? split(ARGS[1], ",") : ["D", "E", "G", "I"]
for item in items
    ref = JSON.parsefile(joinpath(@__DIR__, "ref", jsname, item * ".json"))["results"]
    byname = Dict((r["case"], r["mode"]) => r for r in ref)
    diffs = String[]
    for c in cases
        src = Base64.base64decode(c["src"])
        src_resize(Int32(length(src))); copyto!(SRC, src)
        for m in MODES[item]
            r = byname[(c["name"], m)]
            got = try
                ITEMS[item](Int32(m)); bytes2hex(SHA.sha256(OUT))
            catch e
                "EXC " * string(nameof(typeof(e)))
            end
            want = haskey(r, "exc") ? r["exc"] : r["sha"]
            got == want || push!(diffs, "$(c["name"]) mode $m" * (startswith(got, "EXC") ? " ($got)" : ""))
        end
    end
    println("$item ($jsname, patched natively): $(length(diffs)) of $(length(ref)) runs differ",
            isempty(diffs) ? "" : ": " * join(diffs, ", "))
end
