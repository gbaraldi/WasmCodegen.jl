# Elements of memories of numbers that Julia leaves undefined (a Vector's capacity beyond its
# extent, a Dict's slots without an entry) are zeros in the module, not the bytes the build's
# memory held there: the module is the same whatever they held, and the values are the same.
# A memory referred to otherwise than by such owners is kept whole.

const IU_MARK = 0x5a17c0de5a17c0de
# a Vector whose capacity holds earlier values: 3 of 64
const IU_VEC = let v = fill(IU_MARK, 64)
    resize!(v, 3); v[1] = 1; v[2] = 2; v[3] = 3
    v
end
# a Vector whose extent starts after its memory's first element
const IU_POPPED = let v = UInt64[IU_MARK + 0x100 + i for i in 1:100]
    popfirst!(v)
    v
end
# a Dict whose deleted entries' keys and values stay in its memories
const IU_DICT = let d = Dict{UInt64,UInt64}(IU_MARK + 0x200 + i => IU_MARK + 0x300 + i for i in 1:40)
    for i in 2:40
        delete!(d, IU_MARK + 0x200 + i)
    end
    d
end
# a memory referred to as a memory too, not only by an Array: all of it kept
const IU_SHARED = let m = Memory{UInt64}(undef, 64)
    fill!(m, IU_MARK + 0x400)
    (Base.wrap(Array, m, 2), m)
end

function iu_values(k::Int)
    w = copy(IU_VEC); push!(w, 9)
    return (length(IU_VEC), IU_VEC[k], sum(IU_VEC), w[end], length(w),
            length(IU_POPPED), IU_POPPED[k], IU_POPPED[end],
            IU_SHARED[1][k], length(IU_SHARED[1]), IU_SHARED[2][64])
end
function iu_dict(k::Int)
    d = copy(IU_DICT); d[IU_MARK + 5] = UInt64(5)
    p = first(IU_DICT)
    return (length(IU_DICT), get(IU_DICT, IU_MARK + 0x200 + UInt64(k), UInt64(0)),
            haskey(IU_DICT, IU_MARK + 0x202), p[1], p[2], length(d), get(d, IU_MARK + 5, UInt64(0)))
end

# whether the module has the 8 bytes of `x` (little-endian, as a data segment holds them)
iu_has(bytes::Vector{UInt8}, x::UInt64) = findfirst(reinterpret(UInt8, [x]), bytes) !== nothing

# the same Vector (and memory) with other bytes beyond its extent: the same module
const IU_BOX = UInt64[11, 22]
iu_box(k::Int) = IU_BOX[k] + UInt64(length(IU_BOX))
function iu_rebuild(seed::Int)
    resize!(IU_BOX, 600)
    for i in 3:600
        IU_BOX[i] = hash(i, UInt(seed))
    end
    resize!(IU_BOX, 2)
    return WasmCodegen.compile(iu_box, (Int,); config=test_config()).bytes
end

@testset "undefined elements of memories in the image" begin
    @wtest iu_values(1)
    @wtest iu_values(2)
    @wtest iu_values(3)
    @wtest iu_dict(1)
    @wtest iu_dict(2)
    bytes = vcat(wcompile(iu_values, (Int,)).bytes, wcompile(iu_dict, (Int,)).bytes)
    # beyond the extents: zeros
    @test !iu_has(bytes, IU_MARK)
    @test !iu_has(bytes, IU_MARK + 0x101)
    @test !any(i -> iu_has(bytes, IU_MARK + 0x200 + i), 2:40)
    @test !any(i -> iu_has(bytes, IU_MARK + 0x300 + i), 2:40)
    # within them: kept
    @test iu_has(bytes, IU_MARK + 0x102)
    @test iu_has(bytes, IU_MARK + 0x201) && iu_has(bytes, IU_MARK + 0x301)
    # what the build's memory held beyond a Vector's extent does not change the module
    @test iu_rebuild(1) == iu_rebuild(2)
    @wtest iu_box(2)
end
