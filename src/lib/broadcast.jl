#                        .-'''-.                               _..._
#                       '   _    \         _______          .-'_..._''.
#  /|                 /   /` '.   \        \  ___ `'.     .' .'      '.\
#  ||                .   |     \  '         ' |--.\  \   / .'
#  ||        .-,.--. |   '      |  '        | |    \  ' . '                                     .|
#  ||  __    |  .-. |\    \     / /  __     | |     |  '| |                 __                .' |_
#  ||/'__ '. | |  | | `.   ` ..' /.:--.'.   | |     |  || |              .:--.'.         _  .'     |
#  |:/`  '. '| |  | |    '-...-'`/ |   \ |  | |     ' .'. '             / |   \ |      .' |'--.  .-'
#  ||     | || |  '-             `" __ | |  | |___.' /'  \ '.          .`" __ | |     .   | / |  |
#  ||\    / '| |                  .'.''| | /_______.'/    '. `._____.-'/ .'.''| |   .'.'| |// |  |
#  |/\'..' / | |                 / /   | |_\_______|/       `-.______ / / /   | |_.'.'.-'  /  |  '.'
#  '  `'-'`  |_|                 \ \._,\ '/                          `  \ \._,\ '/.'   \_.'   |   /
#                                 `--'  `"                               `--'  `"             `'-'

using Base.Broadcast
using Base.Broadcast: Broadcasted, AbstractArrayStyle, broadcasted, materialize

# There's a saying that debugging code is about twice as hard as writing it in
# the first place. So if you're as clever as you can be when writing code, how
# will you ever debug it?

# AD faces a similar dilemma: if you write code that's as clever as the compiler
# can handle, how will you ever differentiate it? Differentiating makes clever
# code that bit more complex and the compiler gives up, usually resulting in
# 100x worse performance.

# Base's broadcasting is very cleverly written, and this makes differentiating
# it... somewhat tricky.

# Utilities
# =========

accum_sum(xs; dims = :) = reduce(accum, xs, dims = dims)

# Work around reducedim_init issue
# https://github.com/JuliaLang/julia/issues/31427
accum_sum(xs::Nothing; dims = :) = nothing
accum_sum(xs::AbstractArray{Nothing}; dims = :) = nothing
accum_sum(xs::AbstractArray{<:Number}; dims = :) = sum(xs, dims = dims)
accum_sum(xs::AbstractArray{<:AbstractArray{<:Number}}; dims = :) = sum(xs, dims = dims)
accum_sum(xs::Number; dims = :) = xs

# https://github.com/FluxML/Zygote.jl/issues/594
function Base.reducedim_init(::typeof(identity), ::typeof(accum), A::AbstractArray, region)
  Base.reducedim_initarray(A, region, nothing, Union{Nothing,eltype(A)})
end

trim(x, Δ) = reshape(Δ, ntuple(i -> size(Δ, i), Val(ndims(x))))
trim(x::Tuple, Δ) = ntuple(k -> Δ[k], length(x))

unbroadcast(x::AbstractArray, x̄) =
  size(x) == size(x̄) ? x̄ :
  length(x) == length(x̄) ? trim(x, x̄) :
    trim(x, accum_sum(x̄, dims = ntuple(i -> size(x, i) == 1 ? i : ndims(x̄)+1, Val(ndims(x̄)))))

unbroadcast(x::Number, x̄) = accum_sum(x̄)
unbroadcast(x::Tuple{<:Any}, x̄) = (accum_sum(x̄),)
unbroadcast(x::Base.RefValue, x̄) = (x=accum_sum(x̄),)
unbroadcast(x::Tuple, x̄) = trim(x, length(x) == length(x̄) ? x̄ : accum_sum(x̄; dims=2:ndims(x̄))) # case length(x) > 1

unbroadcast(x::AbstractArray, x̄::Nothing) = nothing

# Split Reverse Mode
# ==================

# TODO: use DiffRules here. It's complicated a little by the fact that we need
# to do CSE, then broadcast-ify the expression so that the closure captures the
# right arrays.

@adjoint broadcasted(::typeof(+), xs::Numeric...) =
  broadcast(+, xs...), ȳ -> (nothing, map(x -> unbroadcast(x, ȳ), xs)...)

@adjoint broadcasted(::typeof(-), x::Numeric, y::Numeric) = x .- y,
  Δ -> (nothing, unbroadcast(x, Δ), -unbroadcast(y, Δ))

@adjoint broadcasted(::typeof(*), x::Numeric, y::Numeric) = x.*y,
   Δ -> (nothing, unbroadcast(x, Δ .* conj.(y)), unbroadcast(y, Δ .* conj.(x)))
@adjoint function broadcasted(::typeof(*), x::Number, y::AbstractArray{<:Number})
  z, back = pullback(*, x, y)  # this uses dot(y,Δ) instead of Δ .* conj.(y)
  z, Δ -> (nothing, back(Δ)...)
end
@adjoint function broadcasted(::typeof(*), x::AbstractArray{<:Number}, y::Number)
  z, back = pullback(*, x, y)
  z, Δ -> (nothing, back(Δ)...)
end

@adjoint function broadcasted(::typeof(/), x::Numeric, y::Numeric)
  res = x ./ y
  res, Δ -> (nothing, unbroadcast(x, Δ ./ conj.(y)), unbroadcast(y, .-Δ .* conj.(res ./ y)))
end
@adjoint function broadcasted(::typeof(/), x::AbstractArray{<:Number}, y::Number)
  z, back = pullback(/, x, y)
  z, Δ -> (nothing, back(Δ)...)
end

@adjoint function broadcasted(::typeof(Base.literal_pow), ::typeof(^), x::Numeric, exp::Val{p}) where p
  y = Base.literal_pow.(^, x, exp)
  y, ȳ -> (nothing, nothing, ȳ .* p .* conj.(x .^ (p - 1)), nothing)
end

@adjoint broadcasted(::typeof(identity), x::Numeric) = x, Δ -> (nothing, Δ)

@adjoint function broadcasted(::typeof(tanh), x::Numeric)
  y = tanh.(x)
  y, ȳ -> (nothing, ȳ .* conj.(1 .- y.^2))
end

@adjoint broadcasted(::typeof(conj), x::Numeric) =
  conj.(x), z̄ -> (nothing, conj.(z̄))

@adjoint broadcasted(::typeof(real), x::Numeric) =
  real.(x), z̄ -> (nothing, real.(z̄))

@adjoint broadcasted(::typeof(imag), x::Numeric) =
  imag.(x), z̄ -> (nothing, im .* real.(z̄))

@adjoint function broadcasted(::typeof(+), a::AbstractArray{<:Number}, b::Bool)
  y = b === false ? a : a .+ b
  y, Δ -> (nothing, Δ, nothing)
end
@adjoint function broadcasted(::typeof(+), b::Bool, a::AbstractArray{<:Number})
  y = b === false ? a : b .+ a
  y, Δ -> (nothing, nothing, Δ)
end

@adjoint function broadcasted(::typeof(-), a::AbstractArray{<:Number}, b::Bool)
  y = b === false ? a : a .- b
  y, Δ -> (nothing, Δ, nothing)
end
@adjoint function broadcasted(::typeof(-), b::Bool, a::AbstractArray{<:Number})
  b .- a, Δ -> (nothing, nothing, .-Δ)
end

@adjoint function broadcasted(::typeof(*), a::AbstractArray{<:Number}, b::Bool)
  if b === false
    zero(a), Δ -> (nothing, zero(Δ), nothing)
  else
    a, Δ -> (nothing, Δ, nothing)
  end
end
@adjoint function broadcasted(::typeof(*), b::Bool, a::AbstractArray{<:Number})
  if b === false
    zero(a), Δ -> (nothing, nothing, zero(Δ))
  else
    a, Δ -> (nothing, nothing, Δ)
  end
end

# General Fallback
# ================

# The fused reverse mode implementation is the most general but currently has
# poor performance. It works by flattening the broadcast and mapping the call to
# `_pullback` over the input.

# However, the core call
# broadcast(_pullback, (cx,), f, args...)
# is already 10x slower than a simple broadcast (presumably due to inlining
# issues, or something similar) and the other operations needed take it to about
# 100x overhead.

@generated inclen(::NTuple{N,Any}) where N = Val(N+1)

# Avoid hitting special cases for `Adjoint` etc.
_broadcast(f::F, x...) where F = materialize(broadcasted(f, x...))

collapse_nothings(xs::AbstractArray{Nothing}) = nothing
collapse_nothings(xs) = xs

_dual_purefun(::Type{F}) where {F<:Function} = Base.issingletontype(F)
_dual_purefun(::Type) = false
_dual_purefun(::Type{typeof(^)}) = false  # avoid DomainError from negative powers

_dual_safearg(x::Numeric{<:Real}) = true
_dual_safearg(x::Ref{<:Numeric{<:Real}}) = true
_dual_safearg(x::Union{Type,Val,Symbol}) = true  # non-differentiable types
_dual_safearg(x) = false

@adjoint function broadcasted(::AbstractArrayStyle, f::F, args...) where {F}
  T = Broadcast.combine_eltypes(f, args)
  # Avoid generic broadcasting in two easy cases:
  if T == Bool
    return f.(args...), _->nothing 
  elseif T <: Real && isconcretetype(T) && _dual_purefun(F) && all(_dual_safearg, args)
    y, back = broadcast_forward(f, args...)
    return y, ȳ -> (nothing, nothing, back(ȳ)...)
  end
  len = inclen(args)
  y∂b = _broadcast((x...) -> _pullback(__context__, f, x...), args...)
  y = map(first, y∂b)
  function ∇broadcasted(ȳ)
    dxs_zip = map(((_, pb), ȳ₁) -> pb(ȳ₁), y∂b, ȳ)
    dxs = ntuple(len) do i
      collapse_nothings(map(StaticGetter{i}(), dxs_zip))
    end
    (nothing, accum_sum(dxs[1]), map(unbroadcast, args, Base.tail(dxs))...)
  end
  y, ∇broadcasted
end

@adjoint function broadcasted(::AbstractArrayStyle{0}, f, args...)
  y, ∂b = _broadcast((x...) -> _pullback(__context__, f, x...), args...)
  function ∇broadcasted0(ȳ)
    dxs = ∂b(ȳ)
    dxs === nothing && return nothing
    (nothing, dxs...)
  end
  y, ∇broadcasted0
end

# Use the `map` adjoint in this special case, which is the same but applies
# pullbacks in reverse order.
# This leaves regular `broadcast` technically incorrect when the broadcasted
# function is stateful.
# Look, I'm not proud of it, but this is extremely rare in practice.
# @adjoint function broadcasted(f, x)
#   ∇map(__context__, f, x)
# end

@adjoint! (b::typeof(broadcast))(f, args...) = _pullback(__context__, broadcasted, f, args...)

# Forward Mode -- necessary for CUDA, also used as a fast path above

import ForwardDiff
using ForwardDiff: Dual

dual(x, p) = x
dual(x::Real, p) = Dual(x, p)

function dual_function(f::F) where F
  function (args::Vararg{Any,N}) where N
    ds = map(args, ntuple(identity,Val(N))) do x, i
      dual(x, ntuple(j -> i==j, Val(N)))
    end
    return f(ds...)
  end
end

@inline function broadcast_forward(f, args::Vararg{Any,N}) where N
  T = Broadcast.combine_eltypes(f, args)
  out = dual_function(f).(args...)
  eltype(out) <: Dual || return (out, _ -> nothing)
  y = map(x -> x.value, out)
  _back(ȳ, i) = unbroadcast(args[i], ((a, b) -> a*b.partials[i]).(ȳ, out))
  back(ȳ) = ntuple(i -> _back(ȳ, i), N)
  return y, back
end

@init @require CUDA="052768ef-5323-5732-b1bb-66c8b64840ba" begin
  using CUDA
  const CuArrayStyle = CUDA.AbstractGPUArrayStyle

  if isdefined(CUDA, :cufunc)
    @eval @adjoint function broadcasted(::CuArrayStyle, f, args...)
      y, back = broadcast_forward(CUDA.cufunc(f), args...)
      y, ȳ -> (nothing, nothing, back(ȳ)...)
    end
  else # CUDA >= 3.0
    @eval @adjoint function broadcasted(::CuArrayStyle, f, args...)
      y, back = broadcast_forward(f, args...)
      y, ȳ -> (nothing, nothing, back(ȳ)...)
    end
  end

  @adjoint CUDA.CuArray{N,T}(xs::Array) where {N,T} =
    CUDA.CuArray{N,T}(xs), Δ -> (convert(Array, Δ), )

  @adjoint function sum(xs::CUDA.AbstractGPUArray; dims = :)
    placeholder = similar(xs)
    sum(xs, dims = dims), Δ -> (placeholder .= Δ,)
  end
  
  # Make sure sum(f, ::CuArray) uses broadcase through forward-mode defined above
  # Not the ChainRules.rrule which will use the Zygote.Context and thus not be GPU compatible
  @adjoint function sum(f, xs::CUDA.AbstractGPUArray; kws...)
    @assert !haskey(kws, :init) # TODO add init support (julia 1.6)
    return pullback(__context__, (f, xs) -> sum(f.(xs); kws...), f, xs)
  end
  
  @adjoint function Base.convert(::Type{T}, xs::Array)  where {T<:CUDA.AbstractGPUArray}
    Base.convert(T, xs), Δ -> (nothing, Base.convert(Array, Δ),)
  end

  @eval pull_block_vert(sz, Δ::CUDA.CuArray, A::Number) = CUDA.@allowscalar Δ[sz]
end
