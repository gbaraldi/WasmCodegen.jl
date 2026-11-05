# Reusing locals: a local that holds one value (assigned once, read only where that assignment
# reaches) shares its slot with others of the same type whose values are not live at the same
# time. The code generator emits a local per value (section 9 of DESIGN.md), which wasm-opt
# reallocates; a function large enough can have more locals than an engine accepts (V8: 50,000),
# and be too large for wasm-opt's local passes too. This pass only renumbers locals: the
# instructions, and what the structured IR or inlining made of the function, are unchanged.

"""
    reuse_locals!(f::Func) -> Func

Renumber the locals of the defined function `f` so that values whose lifetimes do not overlap
share a slot of their (identical) type, and drop the locals nothing accesses.

A local is *single-valued* when it has exactly one assignment (`local.set`/`local.tee`) `d`, and
every read of it comes after `d` inside the construct body (function body, block, loop, `if` or
`else` arm, `try_table`) that `d` is directly in. In structured control flow every path to such
a read passes through `d` (a branch either leaves the body or goes back to a loop's start
before `d`), so the value is live from `d` to its last read, extended to the end of every loop
the read is in that does not contain `d` (the value is read again on each iteration). Two
single-valued locals of the same type whose ranges are disjoint never hold live values at the
same time, and share a slot. Every other local (the results of `if`s and loop carries, assigned
on several paths; one read before any assignment) keeps a slot of its own. Exceptional edges
(from a `try_table` body to its handler) are forward branches out of the body, covered by the
same reasoning. A read is dominated by its assignment in the body, which is also Wasm's rule for
reading a non-nullable local, so sharing never makes an uninitialized read.
"""
function reuse_locals!(f::Func)
    f.imported === nothing || return f
    body = f.body
    np = length(f.params)
    nl = length(f.locals)
    nl == 0 && return f
    n = length(body)
    # the position of the `else`/`end` closing each construct (and arm) opened at a position
    closer = zeros(Int, n)
    stack = Int[]
    for (p, inst) in enumerate(body)
        op = inst.op
        if op === :block || op === :loop || op === :if || op === :try_table
            push!(stack, p)
        elseif op === :else
            body[stack[end]].op === :if || error("reuse_locals!: an else outside of an if in ", f.name)
            closer[stack[end]] = p
            stack[end] = p          # the else arm, closed by the `end`
        elseif op === :end
            closer[pop!(stack)] = p
        end
    end
    isempty(stack) || error("reuse_locals!: unbalanced structured control flow in ", f.name)
    # per local (index i - np): number of assignments, the assignment, the end of the body it is
    # directly in, the end of its live range, and whether every read is dominated by it
    ndefs = zeros(Int32, nl)
    def = zeros(Int, nl)
    defstop = zeros(Int, nl)
    last = zeros(Int, nl)
    good = trues(nl)
    accessed = falses(nl)
    bodystops = Int[n + 1]        # the end of each open construct body (the function's: past the end)
    loopstarts = Int[]            # the open loops, outermost first: starts and ends
    loopstops = Int[]
    for (p, inst) in enumerate(body)
        op = inst.op
        if op === :block || op === :if || op === :try_table
            push!(bodystops, closer[p])
        elseif op === :loop
            push!(bodystops, closer[p])
            push!(loopstarts, p); push!(loopstops, closer[p])
        elseif op === :else
            bodystops[end] = closer[p]
        elseif op === :end
            pop!(bodystops)
            if !isempty(loopstops) && loopstops[end] == p
                pop!(loopstarts); pop!(loopstops)
            end
        elseif op === :local_get || op === :local_set || op === :local_tee
            i = (inst.imm[1]::Integer) - np + 1
            i <= nl || error("reuse_locals!: no local ", inst.imm[1], " in ", f.name)
            i >= 1 || continue                    # a parameter
            accessed[i] = true
            if op === :local_get
                d = def[i]
                if ndefs[i] != 1 || !(d < p < defstop[i])
                    good[i] = false
                    continue
                end
                # the outermost enclosing loop that does not contain the assignment
                k = searchsortedfirst(loopstarts, d + 1)
                e = k <= length(loopstarts) ? loopstops[k] : p
                last[i] = max(last[i], e)
            else
                ndefs[i] += Int32(1)
                ndefs[i] == 1 || (good[i] = false; continue)
                def[i] = p
                defstop[i] = bodystops[end]
                last[i] = max(last[i], p)
            end
        end
    end
    # slots: single-valued locals by linear scan over their ranges (in order of assignment,
    # releasing the ranges that ended before), per type; the others one each
    newidx = fill(-1, nl)
    newlocals = ValType[]
    single = Int[i for i in 1:nl if accessed[i] && good[i] && ndefs[i] == 1]
    sort!(single; by = i -> def[i])
    byend = sort(single; by = i -> last[i])
    free = Dict{ValType,Vector{Int}}()
    r = 1
    for i in single
        s = def[i]
        while r <= length(byend) && last[byend[r]] < s
            j = byend[r]
            push!(get!(Vector{Int}, free, f.locals[j]), newidx[j])
            r += 1
        end
        t = f.locals[i]
        pool = get(free, t, nothing)
        if pool !== nothing && !isempty(pool)
            newidx[i] = pop!(pool)
        else
            push!(newlocals, t)
            newidx[i] = np + length(newlocals) - 1
        end
    end
    for i in 1:nl
        accessed[i] && newidx[i] < 0 || continue
        push!(newlocals, f.locals[i])
        newidx[i] = np + length(newlocals) - 1
    end
    for (p, inst) in enumerate(body)
        op = inst.op
        if op === :local_get || op === :local_set || op === :local_tee
            i = (inst.imm[1]::Integer) - np + 1
            i >= 1 && (body[p] = Inst(op, (newidx[i],)))
        end
    end
    f.locals = newlocals
    return f
end
