# Reusing locals (`Config(reuse_locals)`, locals.jl): values whose lifetimes do not overlap share a
# local of their type. Only the numbering of locals changes: the modules compute what they did.

using WasmCodegen.WasmBuilder: WModule, add_func!, add_local!, Builder, emit!, block!, loop!, end!, br!,
                               br_if!, finish!, to_bytes, ValType, I64, F64

# a function of the module `m` with locals of types `ts`, its body emitted by `body(b, locals)`
function locals_func(body, ts)
    m = WModule()
    f = add_func!(m, "f", ValType[I64], ValType[I64])
    ls = [add_local!(f, t) for t in ValType[ts...]]
    b = Builder(m, f)
    body(b, ls)
    finish!(b)
    return m, f
end
# the slot each original local has after the pass, from the body's accesses in order
local_slots(f) = [inst.imm[1] for inst in f.body if inst.op in (:local_get, :local_set, :local_tee)]

@testset "locals: reuse" begin
    @testset "straight line: dead values share a slot of their type" begin
        m, f = locals_func([I64, F64, I64, I64]) do b, (a, x, c, unused)
            emit!(b, :local_get, 0); emit!(b, :i64_const, 1); emit!(b, :i64_add); emit!(b, :local_set, a)
            emit!(b, :f64_const, 2.0); emit!(b, :local_set, x)
            emit!(b, :local_get, a); emit!(b, :local_get, a); emit!(b, :i64_mul); emit!(b, :local_set, c)  # a dies, c is born
            emit!(b, :local_get, c); emit!(b, :local_get, x); emit!(b, :i64_trunc_f64_s); emit!(b, :i64_add)
        end
        WasmCodegen.reuse_locals!(f)
        WasmCodegen.WasmBuilder.validate(to_bytes(m))
        @test f.locals == [I64, F64]                  # a and c share; the unused local is gone
        s = local_slots(f)
        @test s[2] == s[4] == s[5] == s[6] == s[7]   # a's set and gets, c's set and get: one i64 slot
        @test s[3] == s[8] != s[2]                   # x: its own (f64)
    end

    @testset "a value read in a loop is live through the loop" begin
        m, f = locals_func([I64, I64, I64]) do b, (a, acc, c)
            emit!(b, :local_get, 0); emit!(b, :local_set, a)
            emit!(b, :i64_const, 0); emit!(b, :local_set, acc)
            block!(b); loop!(b)
            emit!(b, :local_get, acc); emit!(b, :local_get, a); emit!(b, :i64_add); emit!(b, :local_set, c)  # after a's last read
            emit!(b, :local_get, c); emit!(b, :local_set, acc)
            emit!(b, :local_get, acc); emit!(b, :i64_const, 100); emit!(b, :i64_gt_s); br_if!(b, 1)
            br!(b, 0)
            end!(b); end!(b)
            emit!(b, :local_get, acc)
        end
        WasmCodegen.reuse_locals!(f)
        WasmCodegen.WasmBuilder.validate(to_bytes(m))
        s = local_slots(f)
        a, acc, c = s[2], s[3], s[6]
        @test length(f.locals) == 3 && length(unique((a, acc, c))) == 3   # a is read again on the next iteration
    end

    # programs with loops, merges and exceptions, compiled raw: without and with reuse, as native
    locals_poly(x::Float64) = evalpoly(x, ntuple(i -> 1.0 / i, Val(32)))
    function locals_collatz(n::Int)
        steps, m, best = 0, n, n
        while m != 1
            m = iseven(m) ? m >> 1 : 3m + 1
            best = max(best, m)
            steps += 1
        end
        return steps * 1_000_000 + best % 1_000_000
    end
    function locals_try(n::Int)
        a = n * 3
        r = try
            n > 5 && throw(ArgumentError("large"))
            a + 1
        catch
            a - 1
        end
        return r + a
    end
    function locals_tuple(n::Int)
        t = ntuple(i -> (i * n) % 7 + 0.5i, Val(16))
        s = 0.0
        for k in 1:n
            s += t[mod1(k, 16)] * (iseven(k) ? 1 : -1)
        end
        return s
    end
    # (floating point: native fuses muladd on FMA hardware, so against native within rounding;
    # the two modules: bit for bit)
    nlocals(c) = sum(length(fn.locals) for fn in c.cgm.mod.funcs if fn.imported === nothing)
    for (f, args) in ((locals_poly, (1.25,)), (locals_collatz, (27,)), (locals_try, (3,)), (locals_try, (9,)),
                      (locals_tuple, (37,)))
        expected = f(args...)
        got = Dict{Bool,Any}(); n = Dict{Bool,Int}()
        for reuse in (false, true)
            c = WasmCodegen.compile(f, map(Core.Typeof, args); config = test_config(optimize = nothing, reuse_locals = reuse))
            got[reuse] = wasm_run(c, string(nameof(f)), args...; rettype = typeof(expected))
            n[reuse] = nlocals(c)
        end
        @test got[true] === got[false]
        @test expected isa AbstractFloat ? isapprox(got[true], expected; rtol = 1e-14) : got[true] === expected
        @test n[true] < n[false]
    end
end
