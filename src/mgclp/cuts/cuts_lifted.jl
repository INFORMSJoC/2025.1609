function compute_coef_cut_lifted_k(nClient, nSite, prob_j, val_x, val_y, ki_lifted, indy, indx_const)


	# prob_critical_k = critical_k >= 1 ? prob_j[indIs_j[critical_k]] : 0

	coef_cut_lifted = Coef(nClient, nSite)
	coef_cut_lifted.rhs = 0

	prob_j_indy = prob_j[indy]
	ki_lifted_indy = ki_lifted[indy]


	coef_cut_lifted.x[indy] .= 1 .- (1 .- prob_j_indy) .^ ki_lifted_indy .* (1 .+ prob_j_indy .* ki_lifted_indy)
	coef_cut_lifted.y[indy] .= prob_j_indy .* (1 .- prob_j_indy) .^ ki_lifted_indy
	coef_cut_lifted.x[indx_const] .= 1

	# if critical_k == 0
	# 	coef_cut_lifted.x .= prob_j
	# else
	# 	ind = indIs_j[1:critical_k]
	# 	coef_cut_lifted.x[ind] .= prob_j[ind] .- prob_critical_k
	# end
	# val_rhs += coef_cut_lifted.x' * val_x
	return coef_cut_lifted
end

"""
p: probability 
y: y-values
z: z-values
"""
function compute_h_k(p, y, z, k = -1)
	if k == -1
		k = iszero(z) ? 1 : floor(y / z)
	end
	h = p * (1 - p)^k * y + (1 - (1 - p)^k * (k * p + 1)) * z
	return h
end

function compute_coef_cut_lifted_C(nClient, nSite, val_x, val_y, indy, indx_const, prob, j; isprint = false, sepa = false, str = false, ki_lifted = nothing, which_perm::String = "k", is_local_search = true, K::Int = -1)

	sum_val_x = sum(val_x[indx_const])
	if sum_val_x > 1 + EPS
		return nothing
	else
		set_C1, bC1, delta_const = [], 1.0, 0.0
		if which_perm == "clever"

			indy_left = []
			set_C0 = []
			for i in indy
				if isapprox(val_y[i], 1; atol = EPS) && isapprox(val_x[i], 1; atol = EPS)
					push!(set_C1, i)
				elseif isapprox(val_y[i], 0; atol = EPS) && isapprox(val_x[i], 0; atol = EPS)
					push!(set_C0, i)
					# else
					# 	push!(indy_left, i)
				end

			end
			bC1 = prod(1 .- prob[set_C1, j])
			indy_left = setdiff(indy, set_C0, set_C1)
			# if isprint
			# 	@info "indy_left: $(indy_left)"
			# 	@info "val_y[indy_left]: $(val_y[indy_left])"
			# 	@info "val_x[indy_left]: $(val_x[indy_left])"
			# 	@info "prob[indy_left]: $(prob[indy_left, j])"
			# end
			if !isempty(indy_left)

				sum_over_C1 = 0
				sum_over_Ifull = sum(val_x[indx_const])
				v_D_indy_left = [compute_h_k(prob[i, j], val_y[i], val_x[i], ki_lifted[i]) for i in indy_left]
				v_C_indy_left = [prob[i, j] * (val_y[i] - val_x[i]) for i in indy_left]

				# # ===== decide from the current set_C0 and set_C1 only ===== 
				# sum_over_C0 = 0
				# B = 1 - sum_over_C1 - sum_over_C0 - sum_over_Ifull
				# while !isempty(indy_left)
				# 	dict_rhs = Dict(which_set => -1 * ones(length(indy_left)) for which_set in ["C" "D"])
				# 	for ind in eachindex(indy_left)
				# 		i = indy_left[ind]
				# 		dict_rhs["C"][ind] = bC1 * (1 - prob[i, j]) * (B - v_C_indy_left[ind])
				# 		dict_rhs["D"][ind] = bC1 * (B - v_D_indy_left[ind])
				# 	end
				# 	# @info indy_left
				# 	# @info dict_rhs["C"]
				# 	max_val_C, ind_max_C = findmax(dict_rhs["C"])
				# 	max_val_D, ind_max_D = findmax(dict_rhs["D"])
				# 	ind_del = -1
				# 	if max_val_C > max_val_D + EPS
				# 		i = indy_left[ind_max_C]
				# 		@info i, dict_rhs["C"][ind_max_C], dict_rhs["D"][ind_max_C]
				# 		@info B, bC1, prob[i, j], val_y[i], val_x[i]
				# 		ind_del = ind_max_C
				# 		push!(set_C1, i)
				# 		bC1 = bC1 * (1 - prob[i, j])
				# 		B += -v_C_indy_left[ind_max_C]
				# 	else
				# 		i = indy_left[ind_max_D]
				# 		ind_del = ind_max_D
				# 		push!(set_C0, i)
				# 		B += -v_D_indy_left[ind_max_D]
				# 	end
				# 	deleteat!(indy_left, ind_del)
				# 	deleteat!(v_C_indy_left, ind_del)
				# 	deleteat!(v_D_indy_left, ind_del)
				# end
				# # ===== decide from the current set_C0 and set_C1 only ===== 


				if !is_local_search
					# ===== assume every site of indy_left is in set_C0 and always take the largest increase of the rhs =====
					sum_over_C0 = sum(v_D_indy_left)
					B = 1 - sum_over_C1 - sum_over_C0 - sum_over_Ifull
					# if isprint
					# 	@info "v_C_indy_left: $(v_C_indy_left)"
					# 	@info "v_D_indy_left: $(v_D_indy_left)"
					# 	@info "B = $(B) = 1 - $(sum_over_C1) - $(sum_over_C0) - $(sum_over_Ifull)"
					# end
					best_rhs = bC1 * B
					dict_rhs = zeros(length(indy_left))
					while !isempty(indy_left)
						# dict_rhs = Dict(which_set => -1 * ones(length(indy_left)) for which_set in ["C"])
						for ind in eachindex(indy_left)
							i = indy_left[ind]
							dict_rhs[ind] = bC1 * (1 - prob[i, j]) * (B - v_C_indy_left[ind] + v_D_indy_left[ind])
						end
						max_val_C, ind_max_C = findmax(dict_rhs)
						# if isprint
						# 	i = indy_left[ind_max_C]
						# 	@info dict_rhs
						# 	@info i, max_val_C, best_rhs
						# 	@info "old: $(best_rhs) = $(bC1) * $(B)"
						# 	@info "new: $(dict_rhs[ind_max_C]) = $(bC1) * $(1 - prob[i,j]) * ($(B) - $(v_C_indy_left[ind_max_C]) + $(v_D_indy_left[ind_max_C]))"
						# end
						if max_val_C > best_rhs + EPS
							i = indy_left[ind_max_C]
							push!(set_C1, i)
							bC1 = bC1 * (1 - prob[i, j])
							B += -v_C_indy_left[ind_max_C] + v_D_indy_left[ind_max_C]
							best_rhs = max_val_C
							deleteat!(indy_left, ind_max_C)
							deleteat!(v_C_indy_left, ind_max_C)
							deleteat!(v_D_indy_left, ind_max_C)
							deleteat!(dict_rhs, ind_max_C)
						else
							break
						end
					end
					# ===== assume every site of indy_left is in set_C0 and decide one by one whether it enters set_C1 =====
				else
					# ===== local search: a site may enter set_C1 and leave it again =====
					sum_over_C0 = sum(v_D_indy_left)
					B = 1 - sum_over_C1 - sum_over_C0 - sum_over_Ifull
					best_rhs = bC1 * B
					dict_rhs = zeros(length(indy_left))
					while true
						for ind in eachindex(indy_left)
							i = indy_left[ind]
							if in(i, set_C1)
								dict_rhs[ind] = bC1 / (1 - prob[i, j]) * (B + v_C_indy_left[ind] - v_D_indy_left[ind])
							else
								dict_rhs[ind] = bC1 * (1 - prob[i, j]) * (B - v_C_indy_left[ind] + v_D_indy_left[ind])
							end
						end
						max_val_C, ind_max_C = findmax(dict_rhs)
						if max_val_C > best_rhs + EPS
							i = indy_left[ind_max_C]
							if in(i, set_C1)
								deleteat!(set_C1, findfirst(isequal(i), set_C1))
								bC1 = bC1 / (1 - prob[i, j])
								B += v_C_indy_left[ind_max_C] - v_D_indy_left[ind_max_C]
								# @info "!!!"
							else
								push!(set_C1, i)
								bC1 = bC1 * (1 - prob[i, j])
								B += -v_C_indy_left[ind_max_C] + v_D_indy_left[ind_max_C]
							end
							best_rhs = max_val_C
						else
							break
						end
					end
					# ===== local search: a site may enter set_C1 and leave it again =====
				end
			end
		else
			set_C1 = [i for i in indy if 1 - val_x[i] < EPS]
			bC1 = prod(1 .- prob[set_C1, j])
		end
		# if isprint
		# 	@info "set_C1:", set_C1
		# 	@info "bC1: ", bC1
		# 	@info "prob[set_C1]:", prob[set_C1, j]
		# 	@info "val_y[set_C1]:", val_y[set_C1]
		# 	@info "val_x[set_C1]:", val_x[set_C1]
		# end
		coef_cutF = Coef(nClient, nSite)
		coef_cutF.indx_const = indx_const

		# if str == false
		#     for i in indy
		#         coef_cutF.y[i] = bC1 * prob[i, j]
		#     end

		#     for i in set_C1
		#         coef_cutF.x[i] = -coef_cutF.y[i]
		#     end
		# else
		# slope = [val_y[i] / val_x[i] for i in indy if val_x[i] > EPS]
		len_C1 = length(set_C1)
		flag_facet = len_C1 >= K ? false : true
		# if !flag_facet
		# 	@info "len_C1=$(len_C1) >= K=$(K)"
		# end
		for i in indy
			if i in set_C1
				coef_cutF.y[i] = bC1 * prob[i, j]
				coef_cutF.x[i] = -coef_cutF.y[i]
			else
				# ki = val_x[i] > EPS ? max(1, floor(val_y[i] / val_x[i])) : 1
				# ki = 1
				ki = ki_lifted[i]
				if flag_facet && len_C1 + ki_lifted[i] > K - 1
					flag_facet = false
					# if !flag_facet
					# 	@info "len_C1=$(len_C1) + ki=$(ki) > K-1=$(K-1)"
					# end
				end
				coef_cutF.y[i] = bC1 * prob[i, j] * (1 - prob[i, j])^ki
				coef_cutF.x[i] = -coef_cutF.y[i] * ki + bC1 * (1 - (1 - prob[i, j])^ki)
			end
		end
		# end

		coef_cutF.rhs = 1 - bC1
		coef_cutF.x_const = bC1
		return coef_cutF, flag_facet
	end
end
function compute_coef_cut_lifted_C_backup(nClient, nSite, val_x, val_y, indy, indx_const, prob, j; isprint = false, sepa = false, str = false, ki_lifted = nothing, which_perm::String = "k")

	sum_val_x = sum(val_x[indx_const])
	if sum_val_x > 1 + EPS
		return nothing
	else
		set_C1, bC1, delta_const = [], 1.0, 0.0
		if which_perm == "k" || which_perm == "y"
			perm_indy = nothing
			if which_perm == "k"
				perm_indy = sortperm(ki_lifted[indy], rev = true)
			elseif which_perm == "y"
				perm_indy = sortperm(abs.(val_y[indy] .- 1))
			end
			# perm_indy = sortperm(val_y[indy], rev = true)
			v_Ipartial = [compute_h_k(prob[i, j], val_y[i], val_x[i], ki_lifted[i]) for i in indy[perm_indy]]
			sum_v_Ifull = sum(val_x[indx_const])
			sum_v_Ipartial = sum(v_Ipartial)
			vio = 1 - bC1 + bC1 * (sum_v_Ipartial + sum_v_Ifull)
			# @info "ordering: ", indy[perm_indy]
			for ind in eachindex(perm_indy)
				i = indy[perm_indy[ind]]
				if val_y[i] < EPS
					continue
				end
				bC1_new = bC1 * (1 - prob[i, j])
				v_i_new = prob[i, j] * (val_y[i] - val_x[i])
				vio_new = 1 - bC1_new + bC1_new * (sum_v_Ipartial + sum_v_Ifull - v_Ipartial[ind] + v_i_new)
				# if i == 75
				# 	@info "i = $i"
				# 	@info "bC1_new: $bC1_new"
				# 	@info "sum_v_Ipartial: $sum_v_Ipartial"
				# 	@info "sum_v_Ifull: $sum_v_Ifull"
				# 	@info "v_Ipartial[ind]: $(v_Ipartial[ind])"
				# 	@info "v_i_new: $v_i_new"
				# 	@info v_Ipartial
				# 	@info "vio: $vio vio_new: $vio_new"
				# end
				# if i == 75
				# @info "i = $i, bC1"
				# @info 
				# end

				if vio_new < vio - EPS || (vio_new < vio + EPS && isapprox(val_y[i], 1; atol = EPS))
					push!(set_C1, i)
					sum_v_Ipartial += v_i_new - v_Ipartial[ind]
					v_Ipartial[ind] = v_i_new
					bC1 = bC1_new
					vio = vio_new
					# @info "violation at set_C1 being $(set_C1) : $(vio)"
				end
			end

			# set_C1_ = [i for i in indy if 1 - val_x[i] < EPS]
			# bC1_ = prod(1 .- prob[set_C1_, j])
			# vio_ =  1 - bC1_ + bC1_ * (sum_v_Ipartial + sum_v_Ifull - v_Ipartial[ind])
		elseif which_perm == "clever"

			indy_left = []
			set_C0 = []
			for i in indy
				if isapprox(val_y[i], 1; atol = EPS) && isapprox(val_x[i], 1; atol = EPS)
					push!(set_C1, i)
				elseif isapprox(val_y[i], 0; atol = EPS) && isapprox(val_x[i], 0; atol = EPS)
					push!(set_C0, i)
					# else
					# 	push!(indy_left, i)
				end

			end
			bC1 = prod(1 .- prob[set_C1, j])
			indy_left = setdiff(indy, set_C0, set_C1)
			# if isprint
			# 	@info "indy_left: $(indy_left)"
			# 	@info "val_y[indy_left]: $(val_y[indy_left])"
			# 	@info "val_x[indy_left]: $(val_x[indy_left])"
			# 	@info "prob[indy_left]: $(prob[indy_left, j])"
			# end
			if !isempty(indy_left)

				sum_over_C1 = 0
				sum_over_Ifull = sum(val_x[indx_const])
				v_D_indy_left = [compute_h_k(prob[i, j], val_y[i], val_x[i], ki_lifted[i]) for i in indy_left]
				v_C_indy_left = [prob[i, j] * (val_y[i] - val_x[i]) for i in indy_left]

				# # ===== decide from the current set_C0 and set_C1 only ===== 
				# sum_over_C0 = 0
				# B = 1 - sum_over_C1 - sum_over_C0 - sum_over_Ifull
				# while !isempty(indy_left)
				# 	dict_rhs = Dict(which_set => -1 * ones(length(indy_left)) for which_set in ["C" "D"])
				# 	for ind in eachindex(indy_left)
				# 		i = indy_left[ind]
				# 		dict_rhs["C"][ind] = bC1 * (1 - prob[i, j]) * (B - v_C_indy_left[ind])
				# 		dict_rhs["D"][ind] = bC1 * (B - v_D_indy_left[ind])
				# 	end
				# 	# @info indy_left
				# 	# @info dict_rhs["C"]
				# 	max_val_C, ind_max_C = findmax(dict_rhs["C"])
				# 	max_val_D, ind_max_D = findmax(dict_rhs["D"])
				# 	ind_del = -1
				# 	if max_val_C > max_val_D + EPS
				# 		i = indy_left[ind_max_C]
				# 		@info i, dict_rhs["C"][ind_max_C], dict_rhs["D"][ind_max_C]
				# 		@info B, bC1, prob[i, j], val_y[i], val_x[i]
				# 		ind_del = ind_max_C
				# 		push!(set_C1, i)
				# 		bC1 = bC1 * (1 - prob[i, j])
				# 		B += -v_C_indy_left[ind_max_C]
				# 	else
				# 		i = indy_left[ind_max_D]
				# 		ind_del = ind_max_D
				# 		push!(set_C0, i)
				# 		B += -v_D_indy_left[ind_max_D]
				# 	end
				# 	deleteat!(indy_left, ind_del)
				# 	deleteat!(v_C_indy_left, ind_del)
				# 	deleteat!(v_D_indy_left, ind_del)
				# end
				# # ===== decide from the current set_C0 and set_C1 only ===== 


				# ===== assume every site of indy_left is in set_C0 and always take the largest increase of the rhs =====
				sum_over_C0 = sum(v_D_indy_left)
				B = 1 - sum_over_C1 - sum_over_C0 - sum_over_Ifull
				# if isprint
				# 	@info "v_C_indy_left: $(v_C_indy_left)"
				# 	@info "v_D_indy_left: $(v_D_indy_left)"
				# 	@info "B = $(B) = 1 - $(sum_over_C1) - $(sum_over_C0) - $(sum_over_Ifull)"
				# end
				best_rhs = bC1 * B
				while !isempty(indy_left)
					dict_rhs = Dict(which_set => -1 * ones(length(indy_left)) for which_set in ["C"])
					for ind in eachindex(indy_left)
						i = indy_left[ind]
						dict_rhs["C"][ind] = bC1 * (1 - prob[i, j]) * (B - v_C_indy_left[ind] + v_D_indy_left[ind])
					end
					max_val_C, ind_max_C = findmax(dict_rhs["C"])
					# if isprint
					# 	i = indy_left[ind_max_C]
					# 	@info dict_rhs["C"]
					# 	@info i, max_val_C, best_rhs
					# 	@info "old: $(best_rhs) = $(bC1) * $(B)"
					# 	@info "new: $(dict_rhs["C"][ind_max_C]) = $(bC1) * $(1 - prob[i,j]) * ($(B) - $(v_C_indy_left[ind_max_C]) + $(v_D_indy_left[ind_max_C]))"
					# end
					if max_val_C > best_rhs + EPS
						i = indy_left[ind_max_C]
						push!(set_C1, i)
						bC1 = bC1 * (1 - prob[i, j])
						B += -v_C_indy_left[ind_max_C] + v_D_indy_left[ind_max_C]
						best_rhs = max_val_C
						deleteat!(indy_left, ind_max_C)
						deleteat!(v_C_indy_left, ind_max_C)
						deleteat!(v_D_indy_left, ind_max_C)
					else
						break
					end
				end
				# ===== assume every site of indy_left is in set_C0 and decide one by one whether it enters set_C1 =====
			end
		elseif sepa == true
			set_C1 = [i for i in indy if 1 - val_x[i] < EPS]
			if !isempty(set_C1)
				bC1 = prod(1 .- prob[set_C1, j])
			end
			delta_const = 1 - sum_val_x - (prob[indy, j] .* (1 .- prob[indy, j]))' * (val_y[indy] .- val_x[indy]) - prob[indy, j]' * val_x[indy]
			if !isempty(set_C1)
				delta_const += (prob[set_C1, j] .* (1 .- prob[set_C1, j]))' * (val_y[set_C1] .- val_x[set_C1]) + prob[set_C1, j]' * val_x[set_C1] - prob[set_C1, j]' * (val_y[set_C1] .- val_x[set_C1])
			end
			# end
			ind_nonzero = [i for i in setdiff(indy, set_C1) if val_x[i] > EPS]
			num_nnz = length(ind_nonzero)
			if bC1 < EPS
				return nothing
			end
			if num_nnz > 0
				pseudo_set_C1, bC1_part2 = get_set_C1_by_x(num_nnz, prob[ind_nonzero, j], val_x[ind_nonzero], val_y[ind_nonzero], delta_const, bC1; isprint = false, str = false)
				# pseudo_set_C1, bC1_part2 = get_set_C1(num_nnz, prob_j[ind_nonzero], val_x[ind_nonzero], delta_const; isprint=false)
				set_C1 = union(set_C1, ind_nonzero[pseudo_set_C1])
				bC1 = bC1 * bC1_part2
				if bC1 < EPS
					return nothing
				end
			end
		else
			set_C1 = [i for i in indy if 1 - val_x[i] < EPS]
			bC1 = prod(1 .- prob[set_C1, j])
		end
		# if isprint
		# 	@info "set_C1:", set_C1
		# 	@info "bC1: ", bC1
		# 	@info "prob[set_C1]:", prob[set_C1, j]
		# 	@info "val_y[set_C1]:", val_y[set_C1]
		# 	@info "val_x[set_C1]:", val_x[set_C1]
		# end
		coef_cutF = Coef(nClient, nSite)
		coef_cutF.indx_const = indx_const

		# if str == false
		#     for i in indy
		#         coef_cutF.y[i] = bC1 * prob[i, j]
		#     end

		#     for i in set_C1
		#         coef_cutF.x[i] = -coef_cutF.y[i]
		#     end
		# else
		# slope = [val_y[i] / val_x[i] for i in indy if val_x[i] > EPS]
		for i in indy
			if i in set_C1
				coef_cutF.y[i] = bC1 * prob[i, j]
				coef_cutF.x[i] = -coef_cutF.y[i]
			else
				# ki = val_x[i] > EPS ? max(1, floor(val_y[i] / val_x[i])) : 1
				ki = 1
				coef_cutF.y[i] = bC1 * prob[i, j] * (1 - prob[i, j])^ki
				coef_cutF.x[i] = -coef_cutF.y[i] * ki + bC1 * (1 - (1 - prob[i, j])^ki)
			end
		end
		# end

		coef_cutF.rhs = 1 - bC1
		coef_cutF.x_const = bC1
		return coef_cutF
	end
end
