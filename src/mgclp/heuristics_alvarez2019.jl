"""
Heuristics following Alvarez-Miranda and Sinnl (2019).

These routines are opt-in. They do not replace the existing preprocessing
greedy heuristic unless `am_start_heuristic=1` is passed.
"""

function am_solution_from_y(val_y, F, indIs, mode::String; K::Int = 0)
	nSite, nClient = size(F)
	val_y_int = round.(Int, val_y)
	if mode == "Bin"
		K_local = K > 0 ? K : sum(val_y_int)
		val_x = zeros(Int, nSite, max(K_local, 1))
		for i in 1:nSite
			if val_y_int[i] > 0
				val_x[i, 1:val_y_int[i]] .= 1
			end
		end
	else
		val_x = [val_y_int[i] > 0 ? 1 : 0 for i in 1:nSite]
	end
	val_etaM, val_etaP = GetEtaFromScratch(val_x, val_y_int, F, indIs, nSite, nClient, mode)
	return MGCLP(val_x, val_y_int, val_etaM, val_etaP)
end

function am_solution_objective(val_y, F, indIs, theta, mode::String; K::Int = 0)
	sol = am_solution_from_y(val_y, F, indIs, mode; K = K)
	return CalcObj(sol.etaM, sol.etaP, theta), sol
end

function am_greedy_solution(F, theta, K, UBy, indIs, mode::String; guide = nothing)
	nSite, _ = size(F)
	val_y = zeros(Int, nSite)
	order = Int[]
	best_sol = nothing
	for _ in 1:K
		best_i = 0
		best_score = -Inf
		best_obj = -Inf
		best_candidate_sol = nothing
		for i in 1:nSite
			if val_y[i] >= UBy[i]
				continue
			end
			candidate_y = copy(val_y)
			candidate_y[i] += 1
			obj, candidate_sol = am_solution_objective(candidate_y, F, indIs, theta, mode; K = K)
			weight = isnothing(guide) ? 1.0 : max(float(guide[i]), 0.0)
			score = weight * obj
			if score > best_score + EPS || (abs(score - best_score) <= EPS && obj > best_obj + EPS)
				best_i = i
				best_score = score
				best_obj = obj
				best_candidate_sol = candidate_sol
			end
		end
		if best_i == 0
			break
		end
		val_y[best_i] += 1
		push!(order, best_i)
		best_sol = best_candidate_sol
	end
	return best_sol, order
end

function am_local_search_solution(sol::MGCLP, order::Vector{Int}, F, theta, UBy, indIs, mode::String; K::Int = 0)
	nSite, _ = size(F)
	current_y = round.(Int, sol.y)
	current_obj = CalcObj(sol.etaM, sol.etaP, theta)
	seen_values = Set{Int}()
	improve = true
	while improve
		improve = false
		obj_key = round(Int, current_obj / max(EPS, 1e-9))
		if obj_key in seen_values
			break
		end
		push!(seen_values, obj_key)
		for pos in length(order):-1:1
			old_i = order[pos]
			base_y = copy(current_y)
			base_y[old_i] -= 1
			for new_i in 1:nSite
				if base_y[new_i] >= UBy[new_i]
					continue
				end
				candidate_y = copy(base_y)
				candidate_y[new_i] += 1
				obj, candidate_sol = am_solution_objective(candidate_y, F, indIs, theta, mode; K = K)
				if obj > current_obj + EPS
					current_y = round.(Int, candidate_sol.y)
					current_obj = obj
					order[pos] = new_i
					sol = candidate_sol
					improve = true
					break
				end
			end
			if improve
				break
			end
		end
	end
	return sol
end

function am_start_solution(F, theta, K, UBy, indIs, mode::String; local_search::Bool = true)
	nSite, nClient = size(F)
	_, val_y = Greedy_Heuristic4(F, theta, nSite, nClient, K, UBy; mode = mode)
	dict_sol = Dict{Int, Int}(i => round(Int, val_y[i]) for i in 1:nSite if val_y[i] > 0)
	sol = GetSolFromSet(dict_sol, nSite, nClient, F, K, indIs; mode = mode)
	order = Int[]
	for i in 1:nSite
		append!(order, fill(i, round(Int, val_y[i])))
	end
	if local_search && !isnothing(sol)
		sol = am_local_search_solution(sol, order, F, theta, UBy, indIs, mode; K = K)
	end
	return sol
end

function am_site_guide_from_callback(val_x, val_y, mode::String)
	if mode == "Bin" && ndims(val_x) == 2
		return [maximum(val_x[i, :]) for i in 1:size(val_x, 1)]
	end
	return float.(val_y)
end

function am_callback_solution(val_x, val_y, F, theta, K, UBy, indIs, mode::String; local_search::Bool = true)
	guide = am_site_guide_from_callback(val_x, val_y, mode)
	sol, order = am_greedy_solution(F, theta, K, UBy, indIs, mode; guide = guide)
	if local_search && !isnothing(sol)
		sol = am_local_search_solution(sol, order, F, theta, UBy, indIs, mode; K = K)
	end
	return sol
end

function am_push_var_value!(vars, vals, item, value)
	if item isa Number
		return
	end
	push!(vars, item)
	push!(vals, float(value))
end

function am_collect_heuristic_values(mgclp::MGCLP, sol::MGCLP)
	vars = Any[]
	vals = Float64[]
	for idx in eachindex(mgclp.x)
		am_push_var_value!(vars, vals, mgclp.x[idx], sol.x[idx])
	end
	if !isnothing(mgclp.y)
		for idx in eachindex(mgclp.y)
			am_push_var_value!(vars, vals, mgclp.y[idx], sol.y[idx])
		end
	end
	for idx in eachindex(mgclp.etaM)
		am_push_var_value!(vars, vals, mgclp.etaM[idx], sol.etaM[idx])
	end
	if !isnothing(mgclp.etaP)
		for idx in eachindex(mgclp.etaP)
			am_push_var_value!(vars, vals, mgclp.etaP[idx], sol.etaP[idx])
		end
	end
	return vars, vals
end
