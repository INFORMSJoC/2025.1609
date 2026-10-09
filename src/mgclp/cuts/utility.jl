
"""
   GetSortedIndex(mat, dim = 1)
Brief:
   get the sorted index of mat on dim1 (or dim2)
Param:
- mat::Matrix{Float64}     matrix to be sorted 
- dim::Int                 sort on which dimension

Return:
   return the sorted index of mat on dimension-dim
"""
function GetSortedIndex(mat; dim=1, val_rev=true)
   n = size(mat, 1)
   m = size(mat, 2)
   IndSorted = zeros(Int, n, m)
   if dim == 1
      for i in 1:n
         IndSorted[i, :] = sortperm(mat[i, :], rev=val_rev)
      end
   elseif dim == 2
      for j in 1:m
         IndSorted[:, j] = sortperm(mat[:, j], rev=val_rev)
      end
   end
   return IndSorted
end


function GetDictFacility(F, nSite, nClient)
   dict = Dict{Int,Dict{Int,Vector{Int}}}()
   LnFbar = Dict{Int,Dict{Int,Float64}}()
   for j in 1:nClient
      dict[j] = Dict()
      LnFbar[j] = Dict()
      dict[j][1] = [i for i in findall(x -> x > 1 - EPS, F[:, j])]
      dict[j][0] = [i for i in findall(x -> x < EPS, F[:, j])]
      dict[j][-1] = setdiff(1:nSite, union(dict[j][1], dict[j][0]))
      for i in dict[j][-1]
         LnFbar[j][i] = log(1 - F[i, j])
      end
   end
   return dict, LnFbar
end

"""
   GetCriticalK(val, IndSorted)
Brief:
   For each client j, we find the k corresponding to the most violated max-cut:
      - If sum(x[:,j]) >= 1, we get the greatest k such that sum(x[IndSorted[1:(k-1),j],j]) < 1.
      - Otherwise, let k = 0.
   Default 
Param:
- val::Vector{Float64}         
- IndSorted::Matrix{Int64}  

Return:
   the vector of critical k for each client j
"""

"""
GetCriticalK(val, IndSorted; atol=1e-6)

Compute the critical index k for a set of sorted indices IndSorted,
given a set of values val. The critical index k is the smallest index
such that the sum of the values val up to index k exceeds a threshold
value 1 - atol, where atol is a user-defined tolerance parameter.

Arguments:
- val: A one-dimensional array of values.
- IndSorted: A two-dimensional array of sorted indices. IndSorted has n
  rows and m columns, where n is the length of val and m is the number
  of sets of sorted indices. Each column of IndSorted represents a set
  of indices that sort the corresponding elements of val in ascending
  order.
- atol: A user-defined tolerance parameter. Default is 1e-6.

Returns:
- CriticalK: An array of integers with length m, where CriticalK[j] is
  the critical index for the j-th set of sorted indices in IndSorted.
  If any element of val is less than the threshold value 1 - atol, the
  corresponding element of CriticalK is set to zero. Otherwise, if the
  sum of the values val up to index k exceeds the threshold value 1 - atol
  for some index k, the corresponding element of CriticalK is set to k.
  If the sum of the values val up to the last index of IndSorted is less
  than the threshold value 1 - atol, the corresponding element of
  CriticalK is set to n, where n is the length of val.
"""
function GetCriticalK(val, IndSorted; atol=1e-6)
   n = size(IndSorted, 1)
   m = size(IndSorted, 2)
   CriticalK = ones(Int, nSite)
   if sum(val) < 1 - EPS
      return zeros(Int, m)
   end
   for j in 1:m
      sumval = 0
      for k in 1:n
         sumval += val[IndSorted[k, j]]
         if sumval < 1 - atol
            CriticalK[j] = k + 1
         else
            break
         end
      end
   end
   return CriticalK
end

function GetCriticalK_j(val, IndSorted; atol=1e-6)
   n = size(IndSorted, 1)
   m = size(IndSorted, 2)
   CriticalK = ones(Int, nSite)
   if sum(val) < 1 - EPS
      return zeros(Int, m)
   end
   for j in 1:m
      sumval = 0
      for k in 1:n
         sumval += val[IndSorted[k, j]]
         if sumval < 1 - atol
            CriticalK[j] = k + 1
         else
            break
         end
      end
   end
   return CriticalK
end

## the following function is less efficient than the one above
# function GetCriticalK(val, IndSorted; atol=1e-6)
#    n = size(IndSorted, 1)
#    m = size(IndSorted, 2)

#    CriticalK = zeros(Int, m)
#    if sum(val) < 1 - atol
#       return CriticalK
#    end
#    for j in 1:m
#       @inbounds sumval = cumsum(val[IndSorted[:, j]])
#       k = findlast(sumval .< 1 - atol)
#       if k !== nothing
#          CriticalK[j] = k + 1
#       end
#    end
#    return CriticalK
# end

"""
GetProduction(nSite, nClient, val_y, mat, dictF)

Compute the production values for each client based on the current solution.

# Arguments
- `nSite`: the number of production sites
- `nClient`: the number of clients
- `val_y`: a vector of production values for each site
- `mat`: a matrix of the fraction of demand that can be fulfilled by each site for each client
- `dictF`: a dictionary containing fixed production costs for each site

# Returns
- A vector of production values for each client
"""
function GetProduction(nSite, nClient, val_y, mat)
   indy = filter(i -> val_y[i] > 0, 1:nSite)
   PhiP = ones(Float64, nClient)
   for j in 1:nClient
      PhiP[j] = prod((1 .- mat[indy, j]) .^ val_y[indy])
   end
   return PhiP
end

"""
GetEtaFromScratch(input_x, input_y, F, indIs, nSite, nClient, mode)

Compute the Eta values for each client based on the current solution.

# Arguments
- `input_x`: a matrix of binary or integer production values for each site and each client
- `input_y`: a vector of integer production values for each site (only used if `mode` is "Bin")
- `F`: a matrix of the fraction of demand that can be fulfilled by each site for each client
- `indIs`: a matrix of the indices of the top k sites that can fulfill each client's demand
- `nSite`: the number of production sites
- `nClient`: the number of clients
- `mode`: a string indicating whether `input_x` contains binary or integer production values ("Bin" or "Int")

# Returns
- A tuple containing:
    - A vector of EtaM values for each client
    - A vector of EtaP values for each client

# Examples
```julia
nSite = 3
nClient = 2
input_x = [1 0 0; 0 0 1; 1 1 0]
input_y = [1, 0, 1]
F = [0.7 0.8; 0.5 0.6; 0.9 0.4]
indIs = [1 3; 2 1; 3 2]
mode = "Bin"
GetEtaFromScratch(input_x, input_y, F, indIs, nSite, nClient, mode) # returns ([0.6, 0.3], [0.864, 0.58])
```
"""

function GetEtaFromScratch(input_x, input_y, F, indIs, nSite, nClient, mode::String)
   if mode == "Bin"
      # Extract binary production values for each site and total production values for each site
      val_x = input_x[:, 1]
      val_y = [sum(input_x[i, :]) for i in 1:nSite]
   elseif mode == "Int"
      # Copy integer production values for each site and total production values for each site
      val_x = input_x[:]
      val_y = input_y[:]
   end
   # Compute dictionary of fixed production costs and average facility cost
   dictF, LnFbar = GetDictFacility(F, nSite, nClient)
   # Compute EtaP values for each client
   PhiP = GetProduction(nSite, nClient, val_y, F)
   val_etaP_calc = [1 - PhiP[j] for j in 1:nClient]
   # Compute EtaM values for each clients
   CriticalK = GetCriticalK(val_x, indIs)
   val_etaM_calc = [compute_val_etaM(F, val_x, indIs, j, CriticalK) for j in 1:nClient]
   # Return EtaM and EtaP values for each client
   return val_etaM_calc, val_etaP_calc
end



"""
compute_val_etaM(F, val_x, indIs, j, CriticalK)

Compute the EtaM value for a single client.

# Arguments
- `F`: a matrix of the fraction of demand that can be fulfilled by each site for each client
- `val_x`: a vector of production values for each site
- `indIs`: a matrix of the indices of the top k sites that can fulfill each client's demand
- `j`: the index of the client to compute the EtaM value for
- `CriticalK`: a vector of the critical values of k for each client

# Returns
- The EtaM value for the specified client
"""
function compute_val_etaM(F, val_x, indIs, j, CriticalK)
   k = CriticalK[j]
   if k > 1
      r = indIs[k, j]
      f_rj = F[r, j]
      val_cut = f_rj + (F[indIs[1:k-1, j], j] .- f_rj)' * val_x[indIs[1:k-1, j]]
   else
      val_cut = F[indIs[1, j], j]
   end
   return val_cut
end
