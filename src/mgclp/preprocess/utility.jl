
"""
   GetSitesConfinedTo1(F, vec_sites_closed=[])
Brief:
   get the sites which satisfy f_ij <= f_kj for each client j
Param:
- F::Matrix{Float64}     the probability matrix
Return:
   return the index of sites 
"""
function get_sites_closed(nSite, nClient, F)
	vec_sites_closed = Int64[]
	for iprime in 1:nSite
		for i in 1:nSite
			if iprime == i
				continue
			end
			flag = true
			for j in 1:nClient
				if F[i, j] < F[iprime, j] - EPS
					flag = false
					break
				end
			end
			if flag == false
				continue
			elseif !in(i, vec_sites_closed)
				append!(vec_sites_closed, iprime)
				break
			end
		end
	end
	return vec_sites_closed
end


function get_sites_UBone(nSite, nClient, F, vec_sites_closed)
	vec_sites_UBone = Int64[]
	ToBeChecked = setdiff([i for i in 1:nSite], vec_sites_closed)
	for i in ToBeChecked
		flag = true
		for j in 1:nClient
			if F[i, j] > EPS && F[i, j] < 1 - EPS
				flag = false
				break
			end
		end
		if flag == true
			append!(vec_sites_UBone, i)
		end
	end
	return vec_sites_UBone
end



function GetSitesConfinedTok(F, theta, K, UBy, w = nothing, vec_sites_UBone1 = [], vec_sites_closed = []; UB3 = nothing, mode = "Int")

	atol = 1e-6
	nSite, nClient = size(F)
	k_site = Dict{Int, Int}()
	# obj_greedy, sol_greedy = Greedy_Heuristic2(F, theta, nSite, nClient, K, UBy, indIs, dictF, LnFbar, w; mode=mode)
	# @time obj_greedy, val_greedy_y = Greedy_Heuristic3(F, theta, nSite, nClient, K, UBy, indIs, dictF, LnFbar, w; mode=mode)
	obj_greedy, val_greedy_y = Greedy_Heuristic4(F, theta, nSite, nClient, K, UBy, w; mode = mode)

	UB1 = copy(obj_greedy) / (1 - 1 / exp(1))
	UB2 = CalcMarginalGain(F, K, theta; w = nothing)
	UB = min.(UB1, UB2)

	if UB3 !== nothing
		for k in 1:K
			UB[k] = min(UB[k], UB3[k])
		end
	end

	if w === nothing
		w = ones(nClient)
	end

	ind_Site = setdiff(1:nSite, union(vec_sites_UBone1, vec_sites_closed))
	for i in ind_Site
		obj_part_M = theta * (F[:, i]' * w)
		val_one_minus_F = 1 .- F[:, i]
		val_etaP_prod = copy(val_one_minus_F)
		for k in 1:K
			val_etaP_prod = val_etaP_prod .* val_one_minus_F
			obj_part_P = (1 - theta) * ((1 .- val_etaP_prod)' * w)
			objval = obj_part_M + obj_part_P
			if k < K && objval + UB[K-k] < obj_greedy[K]
				k_site[i] = k
				break
			end
		end
	end
	return k_site, val_greedy_y
end


"""
   GetSitesConfinedTo1(F, vec_sites_closed=[])
Brief:
   get the sites which satisfy f_ij = 0 or 1 for each client j
Param:
- F::Matrix{Float64}     the probability matrix
Return:
   return the index of sites 
"""




function CalcMarginalGain(F, K, theta; w = nothing)

	atol = 1e-6
	nSite, nClient = size(F)
	Gain = zeros(nSite, K)
	if w === nothing
		w = ones(size(F))
	end

	UB = zeros(K)
	temp = [theta * sum(w[j] * F[i, j] for j in 1:nClient) + (1 - theta) * sum(w[j] * (1 - (1 - F[i, j])) for j in 1:nClient) for i in 1:nSite]

	indTopK = sortperm(temp, rev = true)
	TopK = [temp[indTopK[k]] for k in 1:min(K, nSite)]  # the K largest values
	UB[1] = TopK[1]
	Greater = trues(nSite)
	#Greater = [true for i in 1:nSite]
	for k in 2:K
		for i in 1:nSite
			if Greater[i] == false
				continue
			end
			gain_ik = sum(w[j] * F[i, j] * (1 - F[i, j])^(k - 1) for j in 1:nClient) * (1 - theta)
			if gain_ik > TopK[K]
				temp = copy(TopK)
				append!(temp, gain_ik)
				indTopK = sortperm(temp, rev = true)
				TopK = [temp[indTopK[k]] for k in 1:K]
			else
				Greater[i] = false
			end
		end
		UB[k] = sum(TopK[1:k])
	end

	return UB
end
