# Entry points that probe how much of JuliaSyntax compiles to WebAssembly, one per item
# (A-I, see README.md). Each takes the source in SRC (written byte by byte by the host), a
# mode, and writes its result as bytes to OUT: the host compares them with the native
# output of the same function (native.jl). Only numbers cross the boundary.
#
# PROBE_JS selects the JuliaSyntax: "base" (Base.JuliaSyntax, as vendored in Julia) or
# "reg" (the registered JuliaSyntax.jl of the environment).

if get(ENV, "PROBE_JS", "base") == "reg"
    import JuliaSyntax
    const JS = JuliaSyntax
else
    const JS = Base.JuliaSyntax
end

const SRC = UInt8[]
const OUT = UInt8[]

src_resize(n::Int32)::Int32 = (resize!(SRC, n); Int32(length(SRC)))
"Set the bytes `4i-3:4i` of the source (little-endian; those past its end are ignored)."
function src_set4(i::Int32, w::Int32)::Int32
    for k in 0:3
        j = 4 * (Int(i) - 1) + k + 1
        j <= length(SRC) && (SRC[j] = ((w >>> (8k)) & 0xff) % UInt8)
    end
    return Int32(0)
end
"The bytes `4i-3:4i` of the output, little-endian."
function out_word(i::Int32)::Int32
    w = UInt32(0)
    for k in 0:3
        j = 4 * (Int(i) - 1) + k + 1
        j <= length(OUT) && (w |= UInt32(OUT[j]) << (8k))
    end
    return reinterpret(Int32, w)
end

src_string() = String(copy(SRC))

# --- writing the output -----------------------------------------------------------------

outb(c::Char) = (push!(OUT, UInt8(c)); nothing)
outs(s::String) = (append!(OUT, codeunits(s)); nothing)
function outi(x::Integer)
    x < 0 && outb('-')
    u = x < 0 ? -unsigned(x) : unsigned(x)
    u == 0 && return outb('0')
    n = length(OUT)
    while u > 0
        push!(OUT, UInt8('0') + (u % 10) % UInt8)
        u = div(u, 10)
    end
    reverse!(OUT, n + 1, length(OUT))
    nothing
end
function outhex(x::Unsigned)
    for k in (8 * sizeof(x) - 4):-4:0
        push!(OUT, UInt8("0123456789abcdef"[((x >>> k) & 0xf) + 1]))
    end
    nothing
end
"A string, length-prefixed, its bytes as they are."
outstr(s::String) = (outi(ncodeunits(s)); outb(':'); outs(s))

"""
A value of an `Expr` tree or of a `SyntaxNode` leaf, exactly (floats by their bits): two
values print the same if they are `==` and of the same type."""
function outval(x)
    if x isa Expr
        outb('(')
        outval(x.head)
        for a in x.args
            outb(' ')
            outval(a)
        end
        outb(')')
    elseif x isa Symbol
        outb('S'); outstr(String(x))
    elseif x isa LineNumberNode
        outb('L'); outi(x.line); outb(' '); outval(x.file)
    elseif x isa QuoteNode
        outs("Q("); outval(x.value); outb(')')
    elseif x isa GlobalRef
        outb('G'); outstr(String(nameof(x.mod))); outb(' '); outstr(String(x.name))
    elseif x isa String
        outb('"'); outstr(x)
    elseif x isa Char
        outb('C'); outhex(reinterpret(UInt32, x))
    elseif x isa Bool
        outb(x ? 'T' : 'F')
    elseif x isa Int64
        outb('I'); outi(x)
    elseif x isa Int128
        outb('J'); outi(x)
    elseif x isa UInt128
        outs("U128x"); outhex(x)
    elseif x isa UInt64
        outs("U64x"); outhex(x)
    elseif x isa UInt32
        outs("U32x"); outhex(x)
    elseif x isa UInt16
        outs("U16x"); outhex(x)
    elseif x isa UInt8
        outs("U8x"); outhex(x)
    elseif x isa Float64
        outs("F64x"); outhex(reinterpret(UInt64, x))
    elseif x isa Float32
        outs("F32x"); outhex(reinterpret(UInt32, x))
    elseif x === nothing
        outb('N')
    elseif x isa BigInt
        # (its digits would need GMP: the sign and the number of limbs only)
        outs("BIG"); outi(x.size)
    else
        outb('?')
    end
    nothing
end

kindnum(k) = Int(reinterpret(UInt16, k))

# --- A: the tokenizer -------------------------------------------------------------------

"1: `tokenize` (kinds, byte ranges, flags); 2: the raw lexer (`Tokenize.Lexer`)."
function item_A(mode::Int32)::Int32
    empty!(OUT)
    if mode == 1
        for t in JS.tokenize(src_string())
            outi(kindnum(JS.kind(t))); outb(' ')
            outi(first(t.range)); outb(' '); outi(last(t.range)); outb(' ')
            outi(JS.flags(t)); outb('\n')
        end
    else
        for t in JS.Tokenize.Lexer(IOBuffer(copy(SRC)))
            outi(kindnum(t.kind)); outb(' ')
            outi(t.startbyte); outb(' '); outi(t.endbyte); outb(' ')
            outi(t.suffix ? 1 : 0); outb('\n')
        end
    end
    return Int32(length(OUT))
end

# --- B: the parser core (the example's output, as text) ----------------------------------

"Parse with rule 1 `:all`, 2 `:statement`, 3 `:atom`; the output nodes and the diagnostics."
function item_B(mode::Int32)::Int32
    empty!(OUT)
    stream = JS.ParseStream(copy(SRC))
    JS.parse!(stream; rule = mode == 1 ? :all : mode == 2 ? :statement : :atom)
    for n in stream.output
        k = JS.kind(n)
        outi(kindnum(k)); outb(' ')
        outi(n.byte_span); outb(' ')
        outi(Int(n.node_span_or_orig_kind)); outb(' ')
        outi(JS.flags(n)); outb('\n')
    end
    for d in stream.diagnostics
        outi(d.first_byte); outb(' '); outi(d.last_byte); outb(' ')
        outs(d.level === :error ? "error" : d.level === :warning ? "warning" : "other"); outb(' ')
        outstr(d.message); outb('\n')
    end
    return Int32(length(OUT))
end

# --- P: the parser alone ----------------------------------------------------------------

"`parse!` of the source as a file, nothing else: the number of output nodes, as text."
function item_P(mode::Int32)::Int32
    empty!(OUT)
    stream = JS.ParseStream(copy(SRC))
    JS.parse!(stream; rule = :all)
    outi(length(stream.output))
    return Int32(length(OUT))
end

# --- C: GreenNode -----------------------------------------------------------------------

function outgreen(n)
    outb('('); outi(kindnum(JS.kind(n))); outb(' '); outi(JS.flags(n)); outb(' '); outi(JS.span(n))
    cs = JS.children(n)
    if cs !== nothing
        for c in cs
            outb(' ')
            outgreen(c)
        end
    end
    outb(')')
end

"The green tree of the source parsed as a file, errors included."
function item_C(mode::Int32)::Int32
    empty!(OUT)
    stream = JS.ParseStream(copy(SRC))
    JS.parse!(stream; rule = :all)
    outgreen(JS.build_tree(JS.GreenNode, stream))
    return Int32(length(OUT))
end

# --- D: SyntaxNode ----------------------------------------------------------------------

function outsyntax(n)
    outb('('); outi(kindnum(JS.kind(n))); outb(' '); outi(JS.flags(n)); outb(' ')
    outi(JS.first_byte(n)); outb(' '); outi(JS.last_byte(n))
    cs = JS.children(n)
    if cs === nothing || isempty(cs)
        outb(' '); outval(n.val)
    else
        for c in cs
            outb(' ')
            outsyntax(c)
        end
    end
    outb(')')
end

"The `SyntaxNode` tree of the source parsed as a file, errors included."
function item_D(mode::Int32)::Int32
    empty!(OUT)
    stream = JS.ParseStream(copy(SRC))
    JS.parse!(stream; rule = :all)
    outsyntax(JS.build_tree(JS.SyntaxNode, stream; filename = "probe.jl"))
    return Int32(length(OUT))
end

# --- E: Expr ----------------------------------------------------------------------------

"1: `parseall(Expr, ...)`; 2: `parsestmt(Expr, ...)` (errors become `Expr(:error)`)."
function item_E(mode::Int32)::Int32
    empty!(OUT)
    s = src_string()
    ex = mode == 1 ? JS.parseall(Expr, s; ignore_errors = true) :
                     JS.parsestmt(Expr, s; ignore_errors = true)
    outval(ex)
    return Int32(length(OUT))
end

# --- F: diagnostics as text -------------------------------------------------------------

"`showerror` of the `ParseError` of `parseall(Expr, ...)`; 1 without color, 2 with."
function item_F(mode::Int32)::Int32
    empty!(OUT)
    try
        JS.parseall(Expr, src_string(); filename = "probe.jl")
        outs("no error")
    catch e
        if e isa JS.ParseError
            io = IOBuffer()
            showerror(mode == 2 ? IOContext(io, :color => true) : io, e)
            append!(OUT, take!(io))
        else
            outs("other exception")
        end
    end
    return Int32(length(OUT))
end

# --- G: parse options -------------------------------------------------------------------

"""
`parseall(Expr, ...)` with `filename = "probe.jl"`, `first_line = 7` and the version 1
`VERSION`, 2 v1.0, 3 v1.6, 4 v1.10: the `Expr`, or the first error's message and bytes."""
function item_G(mode::Int32)::Int32
    empty!(OUT)
    v = mode == 1 ? VERSION : mode == 2 ? v"1.0" : mode == 3 ? v"1.6" : v"1.10"
    try
        outval(JS.parseall(Expr, src_string(); filename = "probe.jl", first_line = 7, version = v))
    catch e
        if e isa JS.ParseError
            d = e.diagnostics[something(findfirst(JS.is_error, e.diagnostics), 1)]
            outs("ERR "); outi(d.first_byte); outb(' '); outi(d.last_byte); outb(' '); outstr(d.message)
        else
            outs("other exception")
        end
    end
    return Int32(length(OUT))
end

# --- H: the parser hook -----------------------------------------------------------------

"`core_parser_hook(code, \"probe.jl\", 1, 0, options)` as `Core._parse` is called; options 1 `:all`, 2 `:statement`, 3 `:atom`."
function item_H(mode::Int32)::Int32
    empty!(OUT)
    r = JS.core_parser_hook(src_string(), "probe.jl", 1, 0, mode == 1 ? :all : mode == 2 ? :statement : :atom)
    outval(r[1]); outb(' '); outi(r[2]::Int)
    return Int32(length(OUT))
end

"`Meta.parseall` (1) and `Meta.parse(...; raise = false)` (2): through `Core._parse`."
function item_H2(mode::Int32)::Int32
    empty!(OUT)
    s = src_string()
    outval(mode == 1 ? Meta.parseall(s; filename = "probe.jl") : Meta.parse(s; raise = false))
    return Int32(length(OUT))
end

# --- I: round trips ---------------------------------------------------------------------

function leaftext(n, pos::Int)
    cs = JS.children(n)
    if cs === nothing || isempty(cs)
        append!(OUT, view(SRC, pos:pos + JS.span(n) - 1))
    else
        for c in cs
            leaftext(c, pos)
            pos += JS.span(c)
        end
    end
    nothing
end

"`ex` (a `:toplevel`) without `LineNumberNode`s, its own included."
toplevel_nolines(ex::Expr) = (filter!(a -> !(a isa LineNumberNode), Base.remove_linenums!(ex).args); ex)

"""
1: the source again, from the leaves of the green tree (the host compares it with the
source); 2: `string` of each statement of `parseall(Expr, ...)`, one per line, then
whether parsing that text again gives an equal `Expr` (`==`, `LineNumberNode`s removed)."""
function item_I(mode::Int32)::Int32
    empty!(OUT)
    if mode == 1
        stream = JS.ParseStream(copy(SRC))
        JS.parse!(stream; rule = :all)
        leaftext(JS.build_tree(JS.GreenNode, stream), 1)
    else
        ex = toplevel_nolines(JS.parseall(Expr, src_string(); ignore_errors = true))
        io = IOBuffer()
        for a in ex.args
            print(io, a)
            print(io, '\n')
        end
        text = take!(io)
        ex2 = toplevel_nolines(JS.parseall(Expr, String(copy(text)); ignore_errors = true))
        outs(ex == ex2 ? "== " : "!= ")
        append!(OUT, text)
    end
    return Int32(length(OUT))
end

const COMMON = [(src_resize, (Int32,)), (src_set4, (Int32, Int32)), (out_word, (Int32,))]
const ITEMS = Dict("A" => item_A, "B" => item_B, "C" => item_C, "D" => item_D, "E" => item_E,
                   "F" => item_F, "G" => item_G, "H" => item_H, "H2" => item_H2, "I" => item_I,
                   "P" => item_P)
"The modes each item runs in, on every source of the corpus."
const MODES = Dict("A" => [1, 2], "B" => [1, 2, 3], "C" => [1], "D" => [1], "E" => [1, 2],
                   "F" => [1, 2], "G" => [1, 2, 3, 4], "H" => [1, 2, 3], "H2" => [1, 2], "I" => [1, 2], "P" => [1])
entries(item) = [COMMON; (ITEMS[item], (Int32,))]
