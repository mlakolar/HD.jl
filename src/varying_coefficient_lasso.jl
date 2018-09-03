
### Kernel functions
abstract type SmoothingKernel{T} end


struct GaussianKernel{T} <: SmoothingKernel{T}
  h::T
end

struct EpanechnikovKernel{T} <: SmoothingKernel{T}
  h::T
end

createKernel(::Type{GaussianKernel{T}}, h::T) where {T <: AbstractFloat} = GaussianKernel{T}(h)
createKernel(::Type{EpanechnikovKernel{T}}, h::T) where {T <: AbstractFloat} = EpanechnikovKernel{T}(h)

evaluate(k::GaussianKernel{T}, x::T, y::T) where {T <: AbstractFloat} = exp(-(x-y)^2. / k.h) / k.h
function evaluate(k::EpanechnikovKernel{T}, x::T, y::T) where {T <: AbstractFloat}
    u = (x - y) / k.h
    abs(u) >= 1. ? zero(T) : 0.75 * (1. - u^2.) / k.h
end


############################################################
#
# local polynomial regression with lasso
#
############################################################

function locpolyl1(
  X::Matrix{T}, z::Vector{T}, y::Vector{T},
  zgrid::Vector{T},
  degree::Int64,
  kernel::SmoothingKernel{T},
  λ0::T,
  options::CDOptions=CDOptions()) where {T <: AbstractFloat}

  # construct inner options because we do not want warmStart = false
  # we want to start from the previous iteration since the points
  # on the grid should be close to each other
  opt = CDOptions(options.maxIter, options.optTol, options.randomize, true, options.numSteps)

  n, p = size(X)
  ep = p * (degree + 1)
  out = spzeros(T, ep, length(zgrid))

  # temporary storage
  w = Array{T}(undef, n)
  wX = Array{T}(undef, n, ep)
  stdX = Array{T}(undef, ep)
  f = CDWeightedLSLoss(y, wX, w)        # inner parts of f will be modified in a loop
  g = ProxL1(λ0, stdX)
  β = SparseIterate(ep)

  ind = 0
  for z0 in zgrid
    ind += 1

    # the following two should update f
    w .= evaluate.(Ref(kernel), z, Ref(z0))
    _expand_X!(wX, X, z, z0, degree)
    _stdX!(stdX, w, wX)

    # solve for β
    coordinateDescent!(β, f, g, opt)
    out[:, ind] = β
  end
  out
end

# leave one out for h selection
function lvocv_locpolyl1(
    X::Matrix{T}, z::Vector{T}, y::Vector{T},
    degree::Int64,                                     # degree of the polynomial
    hArr::Vector{T},
    kernelType::Type{<:SmoothingKernel},
    λ0::T,
    options::CDOptions=CDOptions()) where {T <: AbstractFloat}

    n, p = size(X)
    numH = length(hArr)
    MSE = zeros(numH)

    opt = CDOptions(options.maxIter, options.optTol, options.randomize, true, options.numSteps)

    ep = p * (degree + 1)
    w = Array{T}(undef, n)
    wX = Array{T}(undef, n, ep)
    stdX = Array{T}(undef, ep)
    S = BitArray(undef, ep)

    f = CDWeightedLSLoss(y, wX, w)
    β = SparseIterate(ep)

    for indH = 1:numH
        kernel = createKernel(kernelType, hArr[indH])
        for i = 1:n
            # update variables
            z0 = z[i]
            w .= evaluate.(Ref(kernel), z, Ref(z0))
            w[i] = zero(T)
            _expand_X!(wX, X, z, z0, degree)
            _stdX!(stdX, w, wX)
            _findInitResiduals!(w, wX, y, min(10, ep), f.r)

            # compute sigma
            σ = _getSigma(w, f.r)
            g = ProxL1(λ0 * σ, stdX)
            for iter=1:10
              coordinateDescent!(β, f, g, opt)
              σnew = _getSigma(w, f.r)
              if abs(σnew - σ) / σ < 1e-2
                break
              end
              σ = σnew
              g = ProxL1(λ0 * σ, stdX)
            end

            # refit and make prediction
            get_nonzero_coordinates!(S, β, p, degree)
            Xs = view(wX, :, S)
            Yh = dot(wX[i, S], (Xs' * Diagonal(w) * Xs) \ (Xs' * Diagonal(w) * y))
            MSE[indH] += (Yh - y[i])^2.
        end
    end
    MSE
end


############################################################
#
# local polynomial regression low dimensions
#
############################################################


function _locpoly!(
  wX::Matrix{T}, w::Vector{T},
  X::Union{SubArray{T, 2}, Matrix{T}}, z::Union{SubArray{T, 1}, Vector{T}}, y::Union{SubArray{T, 1}, Vector{T}},
  z0::T, degree::Int64, kernel::SmoothingKernel{T}) where {T <: AbstractFloat}

  w .= sqrt.(evaluate.(Ref(kernel), z, Ref(z0)))    # square root of kernel weights
  _expand_wX!(wX, w, X, z, z0, degree)              # √w ⋅ x ⊗ [1 (zi - z0) ... (zi-z0)^q]
  @. w *= y                                         # √w ⋅ y
  qr!(wX) \ w
end

locpoly(
  X::Matrix{T}, z::Vector{T}, y::Vector{T},
  z0::T, degree::Int64, kernel::SmoothingKernel=GaussianKernel(one(T))) where {T <: AbstractFloat} =
    _locpoly!(Array{T}(length(y), size(X, 2) * (degree+1)), similar(y), X, z, y, z0, degree, kernel)

function locpoly(
  X::Matrix{T}, z::Vector{T}, y::Vector{T},
  zgrid::Vector{T},
  degree::Int64,                                     # degree of the polynomial
  kernel::SmoothingKernel{T}=GaussianKernel(one(T))) where {T <: AbstractFloat}

  n, p = size(X)
  ep = p * (degree + 1)
  out = Array{T}(undef, ep, length(zgrid))
  w = Array{T}(undef, n)
  wX = Array{T}(undef, n, ep)

  ind = 0
  for z0 in zgrid
    ind += 1
    out[:, ind] = _locpoly!(wX, w, X, z, y, z0, degree, kernel)
  end
  out
end


# function locpoly_alt(
#   X::Matrix{T}, z::Vector{T}, y::Vector{T},
#   zgrid::Vector{T},
#   degree::Int64,                                     # degree of the polynomial
#   kernel::SmoothingKernel{T}=GaussianKernel(one(T))) where {T <: AbstractFloat}
#
#   n, p = size(X)
#   ep = p * (degree + 1)
#   out = Array{T}(undef, ep, length(zgrid))
#   w = Array{T}(undef, n)
#   Xt_w_Y = Array{T}(undef, ep)
#   Xt_w_X = Array{T}(undef, ep, ep)
#
#   ind = 0
#   for z0 in zgrid
#       w .= evaluate.(Ref(kernel), z, Ref(z0))
#       _expand_Xt_w_Y!(Xt_w_Y, w, X, z, y, z0, degree)
#       _expand_Xt_w_X!(Xt_w_X, w, X, z, z0, degree)
#       ind += 1
#       out[:, ind] = Xt_w_X \ Xt_w_Y
#   end
#   out
# end


# leave one out for h selection
function lvocv_locpoly(
    X::Matrix{T}, z::Vector{T}, y::Vector{T},
    degree::Int64,                                     # degree of the polynomial
    hArr::Vector{T},
    kernelType::Type{<:SmoothingKernel}) where {T <: AbstractFloat}

    n, p = size(X)
    numH = length(hArr)
    MSE = zeros(numH)

    ep = p * (degree + 1)
    w = Array{T}(undef, n-1)
    wX = Array{T}(undef, n-1, ep)
    indOut = BitArray(undef, n)

    for indH = 1:numH
        kernel = createKernel(kernelType, hArr[indH])
        for i = 1:n
            fill!(indOut, true)
            indOut[i] = false
            Xview = view(X, indOut, :)
            Yview = view(y, indOut)
            Zview = view(z, indOut)

            hbeta = _locpoly!(wX, w, Xview, Zview, Yview, z[i], degree, kernel)

            # make prediction
            Yh = dot(X[i, :], hbeta[1:(degree+1):ep])
            MSE[indH] += (Yh - y[i])^2.
        end
    end
    MSE
end


# # leave one out for h selection
# function lvocv_locpoly(
#     X::Matrix{T}, z::Vector{T}, y::Vector{T},
#     degree::Int64,                                     # degree of the polynomial
#     hArr::Vector{T},
#     kernelType::Type{<:SmoothingKernel}) where {T <: AbstractFloat}
#
#     n, p = size(X)
#     numH = length(hArr)
#     MSE = zeros(numH)
#
#     ep = p * (degree + 1)
#     w = Array{T}(undef, n)
#     Xt_w_Y = Array{T}(undef, ep)
#     Xt_w_X = Array{T}(undef, ep, ep)
#
#     for indH = 1:numH
#         kernel = createKernel(kernelType, hArr[indH])
#         for i = 1:n
#             z0 = z[i]
#             w .= evaluate.(Ref(kernel), z, Ref(z0))
#             w[i] = zero(T)
#             _expand_Xt_w_Y!(Xt_w_Y, w, X, z, y, z0, degree)
#             _expand_Xt_w_X!(Xt_w_X, w, X, z, z0, degree)
#             hbeta = Xt_w_X \ Xt_w_Y
#             # make prediction
#             Yh = dot(X[i, :], hbeta[1:(degree+1):ep])
#             MSE[indH] += (Yh - y[i])^2.
#         end
#     end
#     MSE
# end

############################################################
#
# utils
#
############################################################

"""
For a given z0 finds two closest points in zgrid
and corresponding values of beta. The output is obtained
by interpolating the beta values.
"""
function get_beta!(
       out::Union{SparseVector{T}, Vector{T}},
       zgrid::Vector{T},
       beta_grid::Union{Matrix{T}, SparseMatrixCSC{T}},
       z0::T) where {T <: AbstractFloat}
    id1 = searchsortedlast(zgrid, z0)
    id2 = searchsortedfirst(zgrid, z0)

    if id1 == id2
        out .= beta_grid[:, id1]
    else
        z1 = zgrid[id1]
        z2 = zgrid[id2]
        α = (z0 - z1) / (z2 - z1)
        out .= α * beta_grid[:, id1] .+ (1-α) * beta_grid[:, id2]
    end
    out
end


function get_nonzero_coordinates!(
    S::BitArray,
    β::SparseIterate{T},
    p,
    degree) where {T <: AbstractFloat}

    fill!(S, false)
    for j = 1:p
        nonzero = false
        for k=((j-1)*(degree+1)+1):(j*(degree+1))
            nonzero = nonzero | !iszero(β[k])
        end
        if nonzero
            for k=((j-1)*(degree+1)+1):(j*(degree+1))
                S[k] = true
            end
        end
    end
    S
end


"""
Computes matrix whose each row is equal to
w[i] ⋅ (X[i, :] ⊗ [1, (z - z0), ..., (z-z0)^q])
where q is the degree of the polynomial.

The output matrix is preallocated.
"""
function _expand_wX!(
  wX::Matrix{T},
  w::Vector{T},
  X::Union{SubArray{T, 2}, Matrix{T}},
  z::Union{SubArray{T, 1}, Vector{T}}, z0::T, degree::Int64) where {T <: AbstractFloat}

  n, p = size(X)
  # wX = zeros(n, p*(degree+1))
  for j=1:p
    @inbounds for i=1:n
      v = X[i, j] * w[i]
      df = z[i] - z0
      col = (j-1)*(degree+1) + 1
      @inbounds wX[i, col] = v
      for l=1:degree
        v *= df
        @inbounds wX[i, col + l] = v
      end
    end
  end
  # return qrfact!(tX)
  wX
end


# expands the data matrix X
# each row becomes
# (X[i, :] ⊗ [1, (z - z0), ..., (z-z0)^q])
function _expand_X!(
  tX::Matrix{T},
  X::Union{SubArray{T, 2}, Matrix{T}},
  z::Union{SubArray{T, 1}, Vector{T}}, z0::T, degree::Int64) where {T <: AbstractFloat}

  n, p = size(X)
  for j=1:p
    for i=1:n
      v = X[i, j]
      df = z[i] - z0
      col = (j-1)*(degree+1) + 1
      @inbounds tX[i, col] = v
      for l=1:degree
        v *= df
        @inbounds tX[i, col + l] = v
      end
    end
  end
  tX
end


function _expand_Xt_w_X!(
  Xt_w_X::Matrix{T},
  w::Vector{T}, X::Matrix{T},
  z::Vector{T}, z0::T, degree::Int64) where {T <: AbstractFloat}

  n, p = size(X)
  fill!(Xt_w_X, zero(T))
  @inbounds for j=1:p
    @inbounds for k=j:p
      @inbounds for i=1:n
        # if iszero(w[i])
        #   continue
        # end
        v1 = X[i, j] * w[i]
        df1 = z[i] - z0

        col=(j-1)*(degree+1)+1
        for jj=0:degree
          v2 = X[i, k]
          df2 = z[i] - z0
          if k != j
            krange = 0:degree
          else
            krange = jj:degree
            v2 = v2 * df2^jj
          end

          row = (k-1)*(degree+1)+1
          for kk=krange
            # need X[i, j] * (z[i] - z0)^(jj+kk) * X[i, k] * w[i]
            # v2 = (z[i] - z0)^kk * X[i, k]
            # v1 = (z[i] - z0)^jj * X[i, k] * w[i]
            Xt_w_X[row+kk, col+jj] += v2 * v1
            v2 *= df2
          end
          v1 *= df1
        end
      end
    end
  end

  @inbounds for c=1:size(Xt_w_X, 2)
    for r=c+1:size(Xt_w_X, 1)
      Xt_w_X[c, r] = Xt_w_X[r, c]
    end
  end

  Xt_w_X
end

function _expand_Xt_w_Y!(
  Xt_w_Y::Vector{T},
  w::Vector{T}, X::Matrix{T}, z::Vector{T}, y::Vector{T},
  z0::T, degree::Int64) where {T <: AbstractFloat}

  n, p = size(X)
  fill!(Xt_w_Y, zero(T))
  @inbounds for j=1:p
    @inbounds for i=1:n
      # if iszero(w[i])
      #   continue
      # end
      v = X[i, j] * w[i] * y[i]
      df = z[i] - z0

      col=(j-1)*(degree+1)+1
      @inbounds for jj=0:degree
        # need X[i, j] * (z[i] - z0)^jj * Y[i, k] * w[i]
        Xt_w_Y[col+jj] += v
        v *= df
      end
    end
  end

  Xt_w_Y
end
