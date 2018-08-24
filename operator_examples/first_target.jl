using LinearAlgebra, DiffEqOperators
import DiffEqBase: AbstractDiffEqLinearOperator
import Base: *, size, convert

#############################
# Matrix-free operators
# The operators are defined as a subtype of AbstractDiffEqLinearOperator to make use of the composition
# functionality. In actual code we should define a separate AbstractDerivativeOperator type hierarchy.
# Only the most essential interface for AbstractDiffEqLinearOperator is defined: multiplication,
# size (needed for linear combination) and conversion to AbstractMatrix (needed for linsolve).
struct GenericDerivativeOperator{LT,QT} <: AbstractDiffEqLinearOperator{Float64}
  L::LT
  QB::QT
end
size(LB::GenericDerivativeOperator) = (size(LB.L, 1), size(LB.QB, 2))
*(LB::GenericDerivativeOperator, x::AbstractVector{Float64}) = L.L * (L.QB * x)
convert(::Type{AbstractMatrix}, LB::GenericDerivativeOperator) = convert(AbstractMatrix, LB.L) * convert(AbstractMatrix, LB.QB)

struct UniformDiffusionStencil <: AbstractDiffEqLinearOperator{Float64}
  M::Int
  dx::Float64
end
size(L::UniformDiffusionStencil) = (L.M, L.M+2)
*(L::UniformDiffusionStencil, xbar::AbstractVector{Float64}) = [xbar[i] + xbar[i+2] - 2xbar[i+1] for i = 1:L.M] / L.dx^2
function convert(::Type{AbstractMatrix}, L::UniformDiffusionStencil)
  # spdiagm/diagm always creates a square matrix so we have to construct manually.
  # It's likely that more efficient constructions exist.
  mat = zeros(size(L))
  for i = 1:L.M
    mat[i,i] = 1.0
    mat[i,i+1] = -2.0
    mat[i,i+2] = 1.0
  end
  return mat / L.dx^2
end

struct UniformUpwindStencil{CT} <: AbstractDiffEqLinearOperator{Float64}
  stencil::Vector{Float64}
  M::Int
  dx::Float64
  coeff::CT
end
function UniformUpwindStencil(stencil, M, dx)
  coeff = DiffEqScalar(1.0)
  UniformUpwindStencil(stencil, M, dx, coeff)
end
size(L::UniformUpwindStencil) = (L.M, L.M + length(L.stencil))
function *(L::UniformUpwindStencil, xbar::AbstractVector{Float64})
  # This only covers the case when L.coeff is a scalar. Need to add support for
  # vector coefficients later.
  c = convert(Number, L.coeff)
  # This part should be changed to use the stencil coefficients in L
  if c > 0 # backwards difference
    return [xbar[i+1] - xbar[i] for i = 1:L.M] * (c / L.dx)
  else # forward difference
    return [xbar[i+2] - xbar[i+1] for i = 1:L.M] * (c / L.dx)
  end
end
function convert(::Type{AbstractMatrix}, L::UniformUpwindStencil)
  mat = zeros(size(L))
  c = convert(Number, L.coeff)
  # This part should be changed to use the stencil coefficients in L
  if c > 0 # backwards difference
    for i = 1:L.M
      mat[i,i] = -1.0
      mat[i,i+1] = 1.0
    end
  else # forward difference
    for i = 1:L.M
      mat[i,i+1] = -1.0
      mat[i,i+2] = 1.0
    end
  end
  return mat * (c / L.dx)
end
function *(a::DiffEqScalar, L::UniformUpwindStencil)
  # Need to define *(::DiffEqScalar, ::DiffEqScalar) for this to work
  return UniformUpwindStencil(L.stencil, L.M, L.dx, a * L.coeff)
end

# Overload left multiplication for square upwind operators
GenericUpwindOperator = GenericDerivativeOperator{UniformUpwindStencil{CT},QT} where {CT,QT} 
*(a::DiffEqScalar, LB::GenericUpwindOperator) = GenericDerivativeOperator(a * LB.L, LB.QB)

# TODO: stencil operators for irregular grids

struct QRobin <: AbstractDiffEqLinearOperator{Float64}
  M::Int
  dx::Float64
  al::Float64
  bl::Float64
  ar::Float64
  br::Float64
end
size(Q::QRobin) = (Q.M+2, Q.M)
function *(Q::QRobin, x::AbstractVector{Float64})
  xl = x[2] + 2*Q.al*Q.dx/Q.bl * x[1]
  xr = x[end-1] - 2*Q.ar*Q.dx/Q.br * x[end]
  return [xl; x; xr] # could optimize using LazyArrays.jl
end

######################################
# Mock user interface
# DerivativeOperator serves as a factory method to generate derivative operators.
# It generates either stencil operators (for which xgrid is the extended domain),
# or a square operator if BC is provided (for which xgrid is the interior).
# For the mock interface, BC will always be Robin and is specified as the named tuple
# (al, bl, ar, bl).
function DerivativeOperator(xgrid::AbstractRange{Float64}, dorder, aorder)
  M = length(xgrid) - 2
  dx = step(xgrid)
  # This section will be replaced by DiffEqOperator's Fornberg functions
  if dorder == 2 && aorder == 2
    return UniformDiffusionStencil(M, dx)
  elseif dorder == 1 && aorder == 1
    return UniformUpwindStencil([-1,1], M, dx)
  end
end
function DerivativeOperator(xgrid::AbstractRange{Float64}, dorder, aorder, BC)
  M = length(xgrid) - 2
  dx = step(xgrid)
  if dorder == 2 && aorder == 2
    L = UniformDiffusionStencil(M, dx)
    QB = QRobin(M, dx, BC.al, BC.bl, BC.ar, BC.br)
    return GenericDerivativeOperator(L, QB)
  elseif dorder == 1 && aorder == 1
    L = UniformUpwindStencil([-1,1], M, dx)
    QB = QRobin(M, dx, BC.al, BC.bl, BC.ar, BC.br)
    return GenericDerivativeOperator(L, QB)
  end
end

function DerivativeOperator(xgrid::AbstractVector{Float64}, dorder, aorder)
  error("Irregular grid not yet supported") # TODO
end
function DerivativeOperator(xgrid::AbstractVector{Float64}, dorder, aorder, BC)
  error("Irregular grid not yet supported") # TODO
end
