function Greedy_Heuristic4(F, theta, nSite, nClient, K, UBy, w = nothing; is_print = false, mode = "Int")

	obj_greedy = zeros(K)
	val_y = spzeros(nSite)
	val_etaP_prod = ones(nClient)
	F_CriticalK = zeros(nClient)

	if w === nothing
		w = ones(nClient)
	end


	IndF = [filter(i -> F[i, j] > EPS, 1:nClient) for j in 1:nSite]
	Delta = [F[i, :]' * w for i in 1:nSite]

	# for i in 1:nSite
	#    if UBy[i] < EPS
	#       Delta[i] = -1
	#    end
	# end
	# IndDelta stores a permutation of sites by the descending order of (the upper bound of) their marginal gain
	IndDelta = sortperm(Delta, rev = true)
	for tempK in 1:K
		# @assert tempK < 3
		obj = zeros(nSite)
		obj_i = -1
		ind_i = nothing

		obj_this = -1
		obj_next = -1
		pseudo_i = 1
		flag = true
		while flag
			i = IndDelta[pseudo_i]
			if val_y[i] > UBy[i] - EPS
				obj_this = -1
			else
				gain_etaM = [max(F[i, j] - F_CriticalK[j], 0) for j in IndF[i]]
				gain_etaP = [F[i, j] * val_etaP_prod[j] for j in IndF[i]]
				obj_this = theta * gain_etaM' * w[IndF[i]] + (1 - theta) * gain_etaP' * w[IndF[i]]
			end
			obj[i] = obj_this
			Delta[i] = obj_this
			obj_next = Delta[IndDelta[pseudo_i+1]]
			# @info obj_this, obj_next
			if obj_this + EPS < obj_next
				deleteat!(IndDelta, pseudo_i)
				if val_y[i] > UBy[i] - EPS
					push!(IndDelta, i)
				else
					pos = searchsortedfirst(Delta[IndDelta], obj_this, rev = true)
					insert!(IndDelta, pos, i)
				end
			else
				flag = false
			end
		end

		obj_i, ind_i = findmax(obj)
		# ind_i = IndDelta[ind_max]

		# update the values of F_CriticalK and val_etaP_prod
		for j in IndF[ind_i]
			F_CriticalK[j] = max(F_CriticalK[j], F[ind_i, j])
			val_etaP_prod[j] = val_etaP_prod[j] * (1 - F[ind_i, j])
		end

		val_y[ind_i] += 1
		obj_greedy[tempK] = tempK > 1 ? obj_greedy[tempK-1] + obj_i : obj_i
	end
	# indy, _ = findnz(val_y)
	# dict_sol_greedy = Dict(i => round(Int, val_y[i]) for i in indy)
	return obj_greedy, val_y
end


function LocalSearch(cost, opencost, facilities, CurrSolJ, clients, objvalue)
	FirstCand, SecondCand = ComputeSites(clients, CurrSolJ, cost)
	iternum = 0
	while true
		iternum += 1
		if length(CurrSolJ) != 1
			copycurSolJ = deepcopy(CurrSolJ)
			for j in copycurSolJ
				ContributionJ = -opencost[j]
				for i in 1:clients
					if j == FirstCand[i]
						ContributionJ += (cost[i, SecondCand[i]] - cost[i, FirstCand[i]])
					end
				end
				if ContributionJ < 0
					setdiff!(CurrSolJ, j)
					objvalue += ContributionJ
					FirstCand, SecondCand = ComputeSites(clients, CurrSolJ, cost)
					if length(CurrSolJ) == 1
						break
					end
				end
			end
		end
		currentRemindJ = [j for j in 1:facilities if !(j in CurrSolJ)]
		flag = 0
		for j in currentRemindJ
			gain = -opencost[j]
			netloss = Dict(j1 => -opencost[j1] for j1 in CurrSolJ)
			for i in 1:clients
				if cost[i, j] <= cost[i, FirstCand[i]]
					gain += (cost[i, FirstCand[i]] - cost[i, j])
				else
					if length(CurrSolJ) == 1
						netloss[FirstCand[i]] += (cost[i, j] - cost[i, FirstCand[i]])
					else
						netloss[FirstCand[i]] += (min(cost[i, j], cost[i, SecondCand[i]]) - cost[i, FirstCand[i]])
					end
				end
			end
			mark = 0
			minJ = CurrSolJ[1]
			for j1 in CurrSolJ
				minJ = netloss[j1] < netloss[minJ] ? j1 : minJ
			end
			if gain > 0 && netloss[minJ] > 0
				flag = 1
				mark = 1
				append!(CurrSolJ, j)
				objvalue -= gain
			elseif gain - netloss[minJ] > 0
				flag = 1
				mark = 1
				setdiff!(CurrSolJ, minJ)
				append!(CurrSolJ, j)
				objvalue -= (gain - netloss[minJ])
			end
			if mark == 1
				FirstCand, SecondCand = ComputeSites(clients, CurrSolJ, cost)
				# if length(CurrSolJ) == 1
				#     break
				# end
			end
		end
		if flag == 0
			break
		end
	end
	println("CurrSolJ: ", CurrSolJ)
	println("Local objvalue: ", objvalue)
	println("find times: ", iternum)
	print("Local search time: ")
	return FirstCand, objvalue, CurrSolJ
end


function ComputeSites(clients, setSites, cost)
	site1 = ones(Int16, clients)
	site2 = ones(Int16, clients)
	# update the first and the second nearest site among the current sites
	if length(setSites) == 1
		site1 .= setSites[1]
		site2 .= setSites[1]
	else
		for i in 1:clients
			costSortJ = sortperm(cost[i, setSites])
			site1[i] = setSites[costSortJ[1]]
			site2[i] = setSites[costSortJ[2]]
		end
	end
	return site1, site2
end
