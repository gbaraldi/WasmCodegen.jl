# The corpus (corpus.json): files of the Julia installation, read where they are, and the
# snippets below. Sources are stored as base64, so invalid UTF-8 survives the JSON.
# julia corpus.jl
import Base64, JSON

const SHARE = normpath(Sys.BINDIR, "..", "share", "julia")
const FILES = [
    # Base
    "base/abstractarray.jl", "base/array.jl", "base/show.jl", "base/expr.jl", "base/float.jl",
    "base/essentials.jl", "base/boot.jl", "base/iterators.jl", "base/broadcast.jl", "base/range.jl",
    "base/strings/util.jl", "base/strings/string.jl", "base/multidimensional.jl", "base/errorshow.jl",
    "base/reflection.jl", "base/sort.jl", "base/gmp.jl", "base/intfuncs.jl", "base/bitarray.jl",
    "base/task.jl", "base/operators.jl", "base/char.jl", "base/regex.jl",
    # the parser itself
    "base/JuliaSyntax/src/julia/parser.jl", "base/JuliaSyntax/src/julia/tokenize.jl",
    # big stdlib and Compiler files
    "stdlib/v$(VERSION.major).$(VERSION.minor)/LinearAlgebra/src/matmul.jl",
    "stdlib/v$(VERSION.major).$(VERSION.minor)/REPL/src/LineEdit.jl",
    "stdlib/v$(VERSION.major).$(VERSION.minor)/Test/src/Test.jl",
    "stdlib/v$(VERSION.major).$(VERSION.minor)/Printf/src/Printf.jl",
    "Compiler/src/abstractinterpretation.jl",
]

const SNIPPETS = Pair{String,Vector{UInt8}}[]
snip(name, src::AbstractString) = push!(SNIPPETS, name => Vector{UInt8}(codeunits(src)))
snip(name, src::Vector{UInt8}) = push!(SNIPPETS, name => src)

# valid code (the example's snippets, and literals of every kind)
snip("def", "f(x) = x^2 + 1")
snip("for", "for i in 1:3\n  println(i)\nend")
snip("matrix", "a = [1 2; 3 4]'\nb = a .* 2.5f0")
snip("lambda", "x -> (y; z) |> g")
snip("struct", "struct Foo{T} <: Bar\n    x::T\nend")
snip("macro", "@time begin\n    sum(abs2, rand(10))\nend")
snip("if", "if a\n  b\nelseif c\n  d\nelse\n  e\nend")
snip("strings", "\"interp \$(x) and \$y\" * raw\"\\n\" * \"\"\"\n  tri\n  quoted \$z\n  \"\"\"")
snip("numbers", "1e400 + 0x1p3 + 1_000.5e-3 + 0b101 + 0o17 + 1f0 + 0x1F + 'c' + '\\u2200' + 1.5e-310")
snip("bigints", "x = 170141183460469231731687303715884105727 + 0xffffffffffffffffffffffffffffffff + 123456789012345678901234567890123456789012345")
snip("where", "function (f::F)(args...; kw...) where {F}\n  f.g(args...; kw...)\nend")
snip("unicode", "α = √2; ∂x = ∇ ⋅ v; 🐱 = 1; x′ = x̂ ∘ ŷ")
snip("try", "try\n  error(\"x\")\ncatch e\n  rethrow()\nfinally\n  done()\nend")
snip("docstring", "\"\"\"\n    f(x)\n\nDoc.\n\"\"\"\nf(x) = 1\n@doc \"y\" g")
snip("quote", "ex = :(a + \$b); q = quote x = 1 end; s = :sym; :(:(\$(\$x)))")
snip("cmd", "run(`ls -l \$dir`); r\"a+b\"i; b\"\\x00\"; v\"1.2.3\"")
snip("modules", "module M\nusing Base: a, b\nimport C as D\nexport e\nbaremodule N end\nend")
snip("ops", "a .+= b; c ⊻= d; e <: f >: g; h::Int = 1; i = j ? k : l; m = n...; o = p'; q = r[end]; s = t[begin]")
snip("crlf", "x = 1\r\ny = 2\r\n")
snip("bom", vcat(UInt8[0xef, 0xbb, 0xbf], codeunits("x = 1\n")))
# syntax errors: the parser recovers
snip("err-call", "f(x")
snip("err-assign", "a = = b")
snip("err-binop", "begin\n  x +\nend")
snip("err-function", "function f(\n")
snip("err-comma", "[1, 2,, 3]")
snip("err-float", "1.0.0")
snip("err-string", "x = \"unterminated\ny = 2")
snip("err-char", "c = 'ab'")
snip("err-brackets", "f(a, [b, (c)}")
snip("err-end", "end")
snip("err-keyword", "x = function")
snip("err-dots", "a .. . b")
snip("err-invalid-char", "x = 1 \u00a0 2")
snip("err-utf8", vcat(codeunits("x = \""), UInt8[0xff, 0xfe], codeunits("\"\ny = \xc3")))
snip("err-nul", vcat(codeunits("x = 1"), UInt8[0x00], codeunits(" + 2")))
snip("err-macro", "@ x")
snip("err-interp", "\"\$(\"")
snip("err-truncated", first(read(joinpath(SHARE, "base/show.jl")), 20011))
# syntax that needs a newer Julia than v1.0 (parse G: version = v"1.0", v"1.6", v"1.10")
snip("v-import-as", "import Foo as Bar")             # 1.6
snip("v-ncat", "x = [1;;2]")                         # 1.7
snip("v-destructure", "(; a, b) = x")                # 1.7
snip("v-dotand", "a .&& b")                          # 1.7
snip("v-public", "public foo, bar")                  # 1.11
snip("v-global-const", "global const x = 1")         # 1.8?
snip("v-try-else", "try\n a\ncatch\n b\nelse\n c\nend")   # 1.8
snip("v-unicode-ops", "a ⫪ b; c ⫫ d; e ⥺ f")         # 1.10?
snip("v-juxt", "2x + 3(y)")

function build_corpus()
    cases = Any[]
    for f in FILES
        bytes = read(joinpath(SHARE, f))
        push!(cases, Dict("name" => f, "kind" => "file", "src" => Base64.base64encode(bytes)))
    end
    for (name, bytes) in SNIPPETS
        push!(cases, Dict("name" => name, "kind" => "snippet", "src" => Base64.base64encode(bytes)))
    end
    cases
end

if abspath(PROGRAM_FILE) == @__FILE__
    cases = build_corpus()
    write(joinpath(@__DIR__, "corpus.json"), JSON.json(cases))
    nbytes = sum(c -> length(Base64.base64decode(c["src"])), cases)
    println(length(cases), " sources (", length(FILES), " files, ", length(SNIPPETS), " snippets), ", nbytes, " bytes")
end
