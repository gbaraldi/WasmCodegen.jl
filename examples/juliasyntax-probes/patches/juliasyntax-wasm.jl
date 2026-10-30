# Project patches (`Config(extra_patches)`) that take JuliaSyntax around what WebAssembly
# lacks. `JSMod` is the JuliaSyntax module being compiled (`Config(patch_bindings)`).
# Each one changes behaviour, so each is a workaround, not a fix:
#
# - Integer literals that need a `BigInt` (more than 128 bits) throw: GMP is not in Wasm.
#   Natively they parse to a `BigInt` (`SyntaxNode`) or to `@big_str` (`Expr`).
# - `normalize_identifier` maps JuliaSyntax's custom characters (ɛ µ · · − ℏ) but does not
#   NFC-normalize: utf8proc's decomposition takes a `@cfunction` callback. Identical for
#   identifiers already in NFC.
# - JuliaSyntax's `GlobalRef(Core, name)`s (`@int128_str`, `@uint128_str`, `@big_str`,
#   `@cmd`, `@doc`) are `GlobalRef`s made when the patch is applied, in place of
#   `jl_module_globalref`; any other name is an error.

@eval JSMod begin
    _needs_bigint(str) = throw(ArgumentError("integer literal needs a BigInt: " * String(str)))

    function parse_int_literal(str::AbstractString)
        str = replace(replace(str, '_'=>""), '−'=>'-')
        x = Base.tryparse(Int, str)
        if Int === Int32 && isnothing(x)
            x = Base.tryparse(Int64, str)
        end
        if isnothing(x)
            x = Base.tryparse(Int128, str)
            x === nothing && _needs_bigint(str)
        end
        return x
    end

    function parse_uint_literal(str::AbstractString, k)
        str = replace(str, '_'=>"")
        if startswith(str, '+')
            str = str[2:end]
        end
        ndigits = length(str)-2
        if k == K"HexInt"
            return ndigits <= 2  ? Base.parse(UInt8, str)   :
                   ndigits <= 4  ? Base.parse(UInt16, str)  :
                   ndigits <= 8  ? Base.parse(UInt32, str)  :
                   ndigits <= 16 ? Base.parse(UInt64, str)  :
                   ndigits <= 32 ? Base.parse(UInt128, str) :
                   _needs_bigint(str)
        elseif k == K"BinInt"
            ndigits = length(str)-2
            return ndigits <= 8   ? Base.parse(UInt8, str)   :
                   ndigits <= 16  ? Base.parse(UInt16, str)  :
                   ndigits <= 32  ? Base.parse(UInt32, str)  :
                   ndigits <= 64  ? Base.parse(UInt64, str)  :
                   ndigits <= 128 ? Base.parse(UInt128, str) :
                   _needs_bigint(str)
        elseif k == K"OctInt"
            x = Base.tryparse(UInt64, str)
            if isnothing(x)
                x = Base.tryparse(UInt128, str)
                if isnothing(x) || ndigits > 43
                    _needs_bigint(str)
                end
                return x
            else
                return ndigits <= 3  && x <= typemax(UInt8)  ? UInt8(x)   :
                       ndigits <= 6  && x <= typemax(UInt16) ? UInt16(x)  :
                       ndigits <= 11 && x <= typemax(UInt32) ? UInt32(x)  :
                       ndigits <= 22                         ? x          :
                       ndigits <= 43                         ? UInt128(x) :
                       _needs_bigint(str)
            end
        end
    end

    function normalize_identifier(str)
        isascii(str) && return str
        io = IOBuffer()
        for c in str
            print(io, Char(utf8proc_custom_func(UInt32(c), C_NULL)))
        end
        return String(take!(io))
    end
end

let tests = [:(s === $(QuoteNode(name)) && return $(QuoteNode(GlobalRef(Core, name))))
             for name in (Symbol("@int128_str"), Symbol("@uint128_str"), Symbol("@big_str"),
                          Symbol("@cmd"), Symbol("@doc"))]
    @eval JSMod function _wasm_coreref(s::Symbol)
        $(tests...)
        throw(ArgumentError("GlobalRef(Core, $s): a name the patch does not know"))
    end
end

# Tuples with an element of abstract type (`Tuple{SyntaxHead,Any}`, `Tuple{Any,Int}`): the
# code generator builds only tuples of concrete types. JuliaSyntax's own definitions,
# re-evaluated from its sources with these changes:
# - the operator head it keeps with the argument of a `.` (`(head, arg)`, undone by the
#   fixup of the children) is a `_WasmDotHead`;
# - `parsestmt`/`parseall`/`parseatom` without an index return the tree of `_parse_tree`,
#   `_parse` without the `(tree, next_byte)` tuple.
@eval JSMod struct _WasmDotHead
    head::SyntaxHead
    arg::Any
end

let srcdir = JSMod === Base.JuliaSyntax ?
             joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base", "JuliaSyntax", "src") :
             joinpath(pkgdir(JSMod), "src")
    exprfile = isfile(joinpath(srcdir, "integration", "expr.jl")) ? joinpath(srcdir, "integration", "expr.jl") :
                                                                    joinpath(srcdir, "expr.jl")
    apifile = isfile(joinpath(srcdir, "julia", "parser_api.jl")) ? joinpath(srcdir, "julia", "parser_api.jl") :
                                                                   joinpath(srcdir, "parser_api.jl")
    # evaluate, in JuliaSyntax, the definitions of `names` in `file` after the replacements
    function redefine(file, names, replacements)
        text = read(file, String)
        for (old, new) in replacements
            occursin(old, text) || error("juliasyntax-wasm.jl: no `$old` in $file")
            text = replace(text, old => new)
        end
        found = Set{Symbol}()
        for ex in Meta.parseall(text; filename=file).args
            def = Meta.isexpr(ex, :macrocall) ? ex.args[end] : ex
            Meta.isexpr(def, :function) || continue
            call = def.args[1]
            Meta.isexpr(call, :where) && (call = call.args[1])
            Meta.isexpr(call, :call) && call.args[1] in names || continue
            push!(found, call.args[1])
            Core.eval(JSMod, ex)
        end
        found == Set(names) || error("juliasyntax-wasm.jl: found $found of $names in $file")
    end
    if JSMod === Base.JuliaSyntax
        redefine(exprfile, [:node_to_expr, :_node_to_expr, :fixup_Expr_child],
                 ["GlobalRef(Core, " => "_wasm_coreref(",
                  "args[1] = (firstchildhead, args[1])" => "args[1] = _WasmDotHead(firstchildhead, args[1])",
                  "arg.args[1] isa Tuple" => "arg.args[1] isa _WasmDotHead",
                  "h, a = arg.args[1]::Tuple{SyntaxHead,Any}" =>
                      "h = (arg.args[1]::_WasmDotHead).head; a = (arg.args[1]::_WasmDotHead).arg"])
    else
        redefine(exprfile, [:_leaf_to_Expr, :_internal_node_to_Expr, :_fixup_Expr_children!],
                 ["GlobalRef(Core, " => "_wasm_coreref(",
                  "args[1] = (childheads[1], args[1])" => "args[1] = _WasmDotHead(childheads[1], args[1])",
                  "arg.args[1] isa Tuple" => "arg.args[1] isa _WasmDotHead",
                  "h, a = arg.args[1]::Tuple{SyntaxHead,Any}" =>
                      "h = (arg.args[1]::_WasmDotHead).head; a = (arg.args[1]::_WasmDotHead).arg"])
    end
    redefine(apifile, [:_parse_tree], ["function _parse(rule" => "function _parse_tree(rule",
                                       "    tree, last_byte(stream) + 1\nend" => "    tree\nend"])
    # `_printstyled`: the `:color` of the context as a `Bool` (`!` of an `Any` is a dynamic call)
    redefine(joinpath(srcdir, "utils.jl"), [:_printstyled],
             ["|| !get(io, :color, false)" => "|| !(get(io, :color, false)::Bool)"])
    # `core_parser_hook`: no debug log (an `IO` global), and an error is rethrown, not
    # parsed again by flisp (`jl_fl_parse`, Julia's C parser)
    hookfile = isfile(joinpath(srcdir, "integration", "hooks.jl")) ? joinpath(srcdir, "integration", "hooks.jl") :
                                                                     joinpath(srcdir, "hooks.jl")
    redefine(hookfile, [:core_parser_hook],
             ["!isnothing(_debug_log[])" => "false",
              r"        @error\(\"\"\"JuliaSyntax parser failed.*?code=code\)\n"s => "",
              "        _fl_parse_hook(code, filename, lineno, offset, options)\n" => "        rethrow()\n"])
end

@eval JSMod begin
    parsestmt(::Type{T}, text::AbstractString; kws...) where {T} = _parse_tree(:statement, true, T, text; kws...)
    parseall(::Type{T}, text::AbstractString; kws...) where {T} = _parse_tree(:all, true, T, text; kws...)
    parseatom(::Type{T}, text::AbstractString; kws...) where {T} = _parse_tree(:atom, true, T, text; kws...)
end
