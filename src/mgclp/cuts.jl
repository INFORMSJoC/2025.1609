
include("./cuts/utility.jl")
include("./heuristics_alvarez2019.jl")
include("./cuts/cuts_each_bin.jl")
include("./cuts/cuts_each_basic.jl")
include("./cuts/cuts_lifted.jl")

function select_callback_param(param, CB_stage, num_node, msg)
	_cutM, _cutP, _cutF, _cut_local = param._bool["cutM"], param._bool["cutP"], param._bool["cutF"], param._bool["cutLocal"]
	if CB_stage == "UserCut"
		if msg == "noUC"
			_cutM, _cutP, _cutF, _cut_local = false, false, false, false
		elseif msg == "sparse" && num_node % 50 > 0
			_cutM, _cutP, _cutF, _cut_local = false, false, false, false
		end
	end

	return _cutM, _cutP, _cutF, _cut_local
end

function CallbackCommon(cb_data, CB_stage, mgclp, model, param, nClient, nSite, theta, dictF, indIs, LnFbar, F, CutVector, CutVectorLocal, stat, is_submgclp, UB, sol_greedy)
	nodecount = Ref{CPXLONG}()
	if param._string["solver"] == "cplex"
		status = CPXcallbackgetinfolong(cb_data, CPXCALLBACKINFO_NODECOUNT, nodecount)
		@assert status == 0
	elseif param._string["solver"] == "gurobi"
		nodecount[] = 0
	end


	num_node = nodecount[]
	str_node = num_node == 0 ? "r" : "s"
	str_cbstage = CB_stage == "LazyConstraint" ? "LC" : "UC"
	phase = str_node * str_cbstage


	val_etaM = callback_value.(cb_data, mgclp.etaM)
	val_etaP = isnothing(mgclp.etaP) ? zeros(length(val_etaM)) : callback_value.(cb_data, mgclp.etaP)
	val_x = callback_value_array(cb_data, mgclp.x)
	val_y = !isnothing(mgclp.y) ? callback_value.(cb_data, mgclp.y) :
        (ndims(val_x) == 1 ? val_x : [sum(val_x[i, :]) for i in 1:nSite])



	val_callback = MGCLP(val_x, val_y, val_etaM, val_etaP)

	valueP = Ref{Cdouble}()
	x_p = Vector{Cdouble}(undef, 2)
	obj_p = Ref{Cdouble}()

	if param._string["solver"] == "cplex"
		ret = CPXcallbackgetinfodbl(cb_data, CPXCALLBACKINFO_BEST_BND, valueP)
		ret = CPXcallbackgetincumbent(cb_data, x_p, 0, 1, obj_p)
	end
	best_bound = valueP[]
	best_integer = obj_p[]


	if phase == "rUC"
		gap_improved = abs(best_bound - stat.Bound["best_bound"]) / best_integer * 100
		# @info gap_improved, stat.Round["lp_not_improved"]
		if gap_improved < EPS
			stat.Round["lp_not_improved"] += 1
		else
			stat.Round["lp_not_improved"] = 0
		end
		# @info  "Gap improved: $gap_improved%", stat.Round["lp_not_improved"]
		if stat.Round["lp_not_improved"] >= 10
			return
		end
	end

	# if contains(phase, "sUC")
	# 	stat.Round["num_round"] += 1
	# 	nround = stat.Round["num_round"]
	# 	if nround % param._int["node_space"] > 0
	# 		return 
	# 	end
	# 	@info "!"
	# end



	# _cutM, _cutP, _cutF, _cutLocal = select_callback_param(param, CB_stage, num_node, param._string["msg"])
	_cutM, _cutP, _cutF, _cutLocal = select_callback_param(param, CB_stage, num_node, param._string["msg"])
	flag_control = false
	if phase == "sUC" && param._int["node_space"] > 0
		threshold = ceil(nClient / 500) * num_node
		if threshold < 500
			if num_node % param._int["node_space"] > 0
				flag_control = true
			end
		elseif threshold < 1000
			if num_node % (2 * param._int["node_space"]) > 0
				flag_control = true
			end
		elseif threshold < 2000
			if num_node % (5 * param._int["node_space"]) > 0
				flag_control = true
			end
		else
			flag_control = true
		end
		# @info "!", num_node
	end

	if flag_control
		_cutF = false
		_cutM = false
		_cutP = false
	end
	# @info phase, num_node, param._int["node_space"], _cutP
	mode = param._string["mode"]
	cut_info = Dict()
	if !param._bool["is_root"] || phase != "sUC"
		if mode == "Int"
			val_stable, lambda = nothing, 1
			cut_info, nCutM, nCutP, nCutF = BuildCuts(val_callback, mgclp, phase, CutVector, CutVectorLocal, nClient, nSite, dictF, indIs, LnFbar, F;
				cutM = _cutM, cutP = _cutP, cutF = _cutF, cutLocal = _cutLocal, which_first = param._string["which_first"],# lb_y=lb_y,
				str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param, val_stable = val_stable, lambda = lambda, is_lazy = (CB_stage == "LazyConstraint"))
		elseif mode == "Bin"
			cut_info, nCutM, nCutP = BuildCuts_Bin(val_callback, mgclp, phase, CutVector, nClient, nSite, dictF, indIs, F;
				cutM = _cutM, cutP = _cutP, is_Euclid_norm = param._bool["is_Euclidean"])
		end
	end

	if is_submgclp == true && num_node <= 2
		atol = 0.001
		k = round(sum(val_y) - 1)
		y_sum_expr = !isnothing(mgclp.y) ? sum(mgclp.y) : sum(mgclp.x)
		if CB_stage == "UserCut" && (best_bound - stat.Bound["root_best_bound"]) < atol && k >= 0
			Cut = @build_constraint(y_sum_expr <= k)
			@info CB_stage, k, best_bound, nCutP, nCutM
			MOI.submit(model, MOI.UserCut(cb_data), Cut)
			UB[k+1] = best_bound
		elseif CB_stage == "LazyConstraint" && nCutP + nCutM + nCutF == 0 && k >= 0
			Cut = @build_constraint(y_sum_expr <= k)
			@info CB_stage, k, best_bound, nCutP, nCutM
			MOI.submit(model, MOI.LazyConstraint(cb_data), Cut)
			UB[k+1] = best_bound
		end
	end
	Record(stat, cut_info, phase; best_bound = best_bound, best_integer = best_integer, node = num_node)
	SubmitCuts_CB(model, CutVector, cb_data, CB_stage)


	if contains(phase, "LC")
		flag = true
		for key_i in keys(cut_info)
			if cut_info[key_i].Num[phase] > 0
				flag = false
			end
		end
		obj = theta * sum(val_callback.etaM) + (1 - theta) * sum(val_callback.etaP)
		if flag && obj > best_integer + EPS
			# "fea" holds the incumbent only once a preprocessing or start
			# heuristic has produced one; with pre=0 and am_start_heuristic=0
			# there is none, so this branch must not read it.
			stat.Sol["fea"] = val_callback
		end
	end
end
function CallbackCommon_backup(cb_data, CB_stage, mgclp, model, param, nClient, nSite, dictF, indIs, LnFbar, F, CutVector, CutVectorLocal, stat, is_submgclp, UB, sol_greedy)
	nodecount = Ref{CPXLONG}()
	if param._string["solver"] == "cplex"
		status = CPXcallbackgetinfolong(cb_data, CPXCALLBACKINFO_NODECOUNT, nodecount)
		@assert status == 0
	elseif param._string["solver"] == "gurobi"
		nodecount[] = 0
	end


	num_node = nodecount[]
	str_node = num_node == 0 ? "r" : "s"
	str_cbstage = CB_stage == "LazyConstraint" ? "LC" : "UC"
	phase = str_node * str_cbstage


	val_etaM = callback_value.(cb_data, mgclp.etaM)
	val_etaP = callback_value.(cb_data, mgclp.etaP)
	val_x = callback_value_array(cb_data, mgclp.x)
	val_y = !isnothing(mgclp.y) ? callback_value.(cb_data, mgclp.y) :
        (ndims(val_x) == 1 ? val_x : [sum(val_x[i, :]) for i in 1:nSite])

	val_callback = MGCLP(val_x, val_y, val_etaM, val_etaP)

	valueP = Ref{Cdouble}()
	x_p = Vector{Cdouble}(undef, 2)
	obj_p = Ref{Cdouble}()

	if param._string["solver"] == "cplex"
		ret = CPXcallbackgetinfodbl(cb_data, CPXCALLBACKINFO_BEST_BND, valueP)
		ret = CPXcallbackgetincumbent(cb_data, x_p, 0, 1, obj_p)

	else
	end
	best_bound = valueP[]
	best_integer = obj_p[]


	_cutM, _cutP, _cutF, _cutLocal = select_callback_param(param, CB_stage, num_node, param._string["msg"])
	if stat.Round["last_num_node"] != num_node
		stat.Round["last_num_node"] = num_node
		stat.Round["num_round"] = 0
	end
	if phase == "rUC"
		num_round = stat.Round["num_round"]
		if param._int["node_space"] == 0
			_cutF, _cutP, _cutM = false, false, false
			# _cutF = false
		elseif num_round >= param._int["nsepa"] || num_node % param._int["node_space"] > 0
			_cutF, _cutP, _cutM = false, false, false
			# _cutF = false
		end
	end
	# @info phase, num_node, param._int["node_space"], _cutP
	mode = param._string["mode"]
	if mode == "Int"
		val_stable, lambda = nothing, 1
		# if num_node == 0 && param._bool["cutF_stable"]
		# if param._bool["cutF_stable"] 
		if param._bool["cutF_stable"] && (num_node == 0 || !param._bool["stable_root"])
			if contains(phase, "LC") || stat.Round["count_up"] == 300
				stat.Round["count_down"] = 3
				stat.Round["count_up"] = 0
			end
			if stat.Round["count_down"] > 0 && _cutF
				lambda = 0.5
				val_stable = stat.Sol["fea"]
				stat.Round["count_down"] += -1
				# @info lambda, stat.Round["count_down"]
			else
				stat.Round["count_up"] += 1
			end

			# if contains(phase, "UC") && abs(best_bound - stat.Bound["best_bound"]) < EPS
			#    stat.Round["lp_not_improved"] += 1
			#    if stat.Round["lp_not_improved"] >= 150
			#       lambda = 1.0
			#    elseif stat.Round["lp_not_improved"] >= 100
			#       lambda = 0.0
			#    elseif stat.Round["lp_not_improved"] >= 50
			#       lambda = 1.0
			#    end
			# else
			#    stat.Round["lp_not_improved"] = 0
			# end
		end
		cut_info, nCutM, nCutP, nCutF = BuildCuts(val_callback, mgclp, phase, CutVector, CutVectorLocal, nClient, nSite, dictF, indIs, LnFbar, F;
			cutM = _cutM, cutP = _cutP, cutF = _cutF, cutLocal = _cutLocal, which_first = param._string["which_first"],# lb_y=lb_y,
			str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param, val_stable = val_stable, lambda = lambda, num_node = num_node)
		if nCutF + nCutP + nCutM > 0 && contains(phase, "UC")
			stat.Round["num_round"] += 1
		end
	elseif mode == "Bin"
		cut_info, nCutM, nCutP = BuildCuts_Bin(val_callback, mgclp, phase, CutVector, nClient, nSite, dictF, indIs, F;
			cutM = _cutM, cutP = _cutP, is_Euclid_norm = param._bool["is_Euclidean"])
	end

	if is_submgclp == true && num_node <= 2
		atol = 0.001
		k = round(sum(val_y) - 1)
		y_sum_expr = !isnothing(mgclp.y) ? sum(mgclp.y) : sum(mgclp.x)
		if CB_stage == "UserCut" && (best_bound - stat.Bound["root_best_bound"]) < atol && k >= 0
			Cut = @build_constraint(y_sum_expr <= k)
			@info CB_stage, k, best_bound, nCutP, nCutM
			MOI.submit(model, MOI.UserCut(cb_data), Cut)
			UB[k+1] = best_bound
		elseif CB_stage == "LazyConstraint" && nCutP + nCutM + nCutF == 0 && k >= 0
			Cut = @build_constraint(y_sum_expr <= k)
			@info CB_stage, k, best_bound, nCutP, nCutM
			MOI.submit(model, MOI.LazyConstraint(cb_data), Cut)
			UB[k+1] = best_bound
		end
	end
	Record(stat, cut_info, phase; best_bound = best_bound, best_integer = best_integer, node = num_node)
	SubmitCuts_CB(model, CutVector, cb_data, CB_stage)


	if contains(phase, "LC")
		flag = true
		for key_i in keys(cut_info)
			if cut_info[key_i].Num[phase] > 0
				flag = false
			end
		end
		obj = theta * sum(val_callback.etaM) + (1 - theta) * sum(val_callback.etaP)
		if flag && obj > best_integer + EPS
			stat.Sol["fea"] = val_callback
		end
	end
end

"""
   add_callback_cuts (for int model)

Add callback cuts of max part and the production part

# Arguments 
- `model`:  the model to be optimized
- `mgclp`:  the structure of mgclp that contains all variables
- `F`:      the probability matrix
- `K`:      the maximum number of open facilities
- `nClient`:   the number of clients
- `nSite`:     the number of sites
- `indIs`:     the indices of sites of each clients in descending order
- `cutM`: 

# Returns

"""
function add_callback_cuts(model, mgclp, stat, nClient, nSite, theta, F, indIs, dictF, LnFbar, param;
	is_submgclp = false, UB = nothing, sol_greedy = nothing, UBy = nothing)


	CutVector = Vector{ScalarConstraint{AffExpr, MathOptInterface.LessThan{Float64}}}(undef, 1)
	CutVectorLocal = Vector{ScalarConstraint{AffExpr, MathOptInterface.LessThan{Float64}}}(undef, 1)

	function Cuts_LC(cb_data)
		CallbackCommon(cb_data, "LazyConstraint", mgclp, model, param, nClient, nSite, theta, dictF, indIs, LnFbar, F, CutVector, CutVectorLocal, stat, is_submgclp, UB, sol_greedy)
	end

	function Cuts_UC(cb_data)
		CallbackCommon(cb_data, "UserCut", mgclp, model, param, nClient, nSite, theta, dictF, indIs, LnFbar, F, CutVector, CutVectorLocal, stat, is_submgclp, UB, sol_greedy)
	end

	am_last_heur_node = Ref{Int}(-1)
	function AM_Heuristic(cb_data)
		nodecount = Ref{CPXLONG}()
		if param._string["solver"] == "cplex"
			status = CPXcallbackgetinfolong(cb_data, CPXCALLBACKINFO_NODECOUNT, nodecount)
			@assert status == 0
		else
			nodecount[] = 0
		end
		num_node = Int(nodecount[])
		if num_node == am_last_heur_node[]
			return
		end
		if param._int["am_callback_node_space"] > 0 && num_node % param._int["am_callback_node_space"] != 0
			return
		end
		am_last_heur_node[] = num_node
		mode = param._string["mode"]
		val_etaM = callback_value.(cb_data, mgclp.etaM)
		val_etaP = isnothing(mgclp.etaP) ? zeros(length(val_etaM)) : callback_value.(cb_data, mgclp.etaP)
		val_x = callback_value_array(cb_data, mgclp.x)
		val_y = !isnothing(mgclp.y) ? callback_value.(cb_data, mgclp.y) :
			(ndims(val_x) == 1 ? val_x : [sum(val_x[i, :]) for i in 1:nSite])
		ub_y = param._bool["colocation"] ? (isnothing(UBy) ? ones(Int, nSite) * param._int["K"] : UBy) : ones(Int, nSite)
		sol = am_callback_solution(
			val_x,
			val_y,
			F,
			theta,
			param._int["K"],
			ub_y,
			indIs,
			mode;
			local_search = param._bool["am_local_search"],
		)
		if isnothing(sol)
			return
		end
		vars, vals = am_collect_heuristic_values(mgclp, sol)
		try
			MOI.submit(model, MOI.HeuristicSolution(cb_data), vars, vals)
		catch err
			@debug "AM heuristic solution was not accepted" err
		end
	end

	solver = param._string["solver"]
	if solver == "cplex"
		MOI.set(model, MOI.LazyConstraintCallback(), Cuts_LC)
		MOI.set(model, MOI.UserCutCallback(), Cuts_UC)
		if param._bool["am_callback_heuristic"]
			MOI.set(model, MOI.HeuristicCallback(), AM_Heuristic)
		end
	elseif solver == "gurobi"
		MOI.set(model, MOI.RawOptimizerAttribute("LazyConstraints"), 1)
		MOI.set(model, Gurobi.CallbackFunction(), GRBCuts)
	else
		@info "unknown solver"
	end
end

function add_initial_cuts(model, mgclp, stat, nClient, nSite, dictF, indIs, LnFbar, F, param, K; val_init = nothing, vec_cutM = nothing, vec_cutP = nothing)

	start = time()
	CutVector = Vector{ScalarConstraint{AffExpr, MathOptInterface.LessThan{Float64}}}(undef, 1)
	mode = param._string["mode"]
	phase = "init"
	# cut_info, nCutM, nCutP, nCutF = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
	#    cutM=param._bool["cutM"], cutP=param._bool["cutP"], cutF=param._bool["cutF"],
	#    str=param._bool["str"], is_Euclid_norm=param._bool["is_Euclidean"], param=param)
	# @info nCutM, nCutP, nCutF
	val_etaM_start = ones(nClient)
	val_etaP_start = ones(nClient)
	val_x_start = mode == "Int" ? zeros(nSite) : zeros(nSite, K)
	val_y_start = zeros(nSite)
	if isnothing(val_init) || param._bool["init_val_greedy"] == false
		val_init = MGCLP(val_x_start, val_y_start, val_etaM_start, val_etaP_start)
	else
		# @info theta * sum(val_init.etaM) + (1 - theta) * sum(val_init.etaP)
		val_init.etaM = val_etaM_start
		val_init.etaP = val_etaP_start
	end

	val_zero = MGCLP(val_x_start, val_y_start, val_etaM_start, val_etaP_start)

	if mode == "Int"
		init_scheme = param._string["init_scheme"]
		_cutF, _cutP, _cutM = param._bool["cutF"], param._bool["cutP"], param._bool["cutM"]
		# _cutF, _cutP, _cutM = false, param._bool["cutP"], param._bool["cutM"]
		# @info param._string
		cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
			cutM = _cutM, cutP = _cutP, cutF = _cutF, which_first = param._string["which_first"],
			str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param,
			vec_cutM = vec_cutM, vec_cutP = vec_cutP, model = model)
		# @assert(false)
		if isnothing(vec_cutM) || isnothing(vec_cutP)
			SubmitCuts_LP(model, CutVector)
		end
		Record(stat, cut_info, phase)
		# if contains(init_scheme, "heur")
		# 	if _cutF && init_scheme == "cutF_heur"
		# 		cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		# 			cutM = _cutM, cutP = false, cutF = _cutF, which_first = param._string["which_first"],
		# 			str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param)
		# 		Record(stat, cut_info, phase)
		# 	else
		# 		cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		# 			cutM = _cutM, cutP = _cutP, cutF = false, which_first = param._string["which_first"],
		# 			str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param)
		# 		Record(stat, cut_info, phase)
		# 	end
		# elseif init_scheme == "cutF_origin" && _cutF
		# 	cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		# 		cutM = _cutM, cutP = false, cutF = false, which_first = param._string["which_first"],
		# 		str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param)
		# 	Record(stat, cut_info, phase)

		# 	cut_info, _, _, _ = BuildCuts(val_zero, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		# 		cutM = false, cutP = false, cutF = _cutF, which_first = param._string["which_first"],
		# 		str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param)
		# 	Record(stat, cut_info, phase)
		# else
		# 	@info "Unknown initial cuts! cutF=$(_cutF) cutP=$(_cutP) cutM=$(_cutM)"
		# 	@assert(0)
		# end
		# if !param._bool["init_cutF_zero"]
		#    cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		#       cutM=param._bool["cutM"], cutP=param._bool["cutP"], cutF=param._bool["cutF"], which_first=param._string["which_first"],
		#       str=param._bool["str"], is_Euclid_norm=param._bool["is_Euclidean"], param=param)
		#    Record(stat, cut_info, phase)
		# else
		#    if param._bool["cutF"]
		#       cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		#          cutM=param._bool["cutM"], cutP=false, cutF=false, which_first=param._string["which_first"],
		#          str=param._bool["str"], is_Euclid_norm=param._bool["is_Euclidean"], param=param)
		#       Record(stat, cut_info, phase)

		#       cut_info, _, _, _ = BuildCuts(val_zero, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		#          cutM=false, cutP=false, cutF=true, which_first=param._string["which_first"],
		#          str=param._bool["str"], is_Euclid_norm=param._bool["is_Euclidean"], param=param)
		#       Record(stat, cut_info, phase)
		#    else
		#       cut_info, _, _, _ = BuildCuts(val_init, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		#          cutM=param._bool["cutM"], cutP=param._bool["cutP"], cutF=false, which_first=param._string["which_first"],
		#          str=param._bool["str"], is_Euclid_norm=param._bool["is_Euclidean"], param=param)
		#       Record(stat, cut_info, phase)
		#    end
		# end
		# cut_info, _, _, _ = BuildCuts(val_zero, mgclp, phase, CutVector, CutVector, nClient, nSite, dictF, indIs, LnFbar, F;
		#    cutM=false, cutP=false, cutF=param._bool["cutF"],
		#    str=param._bool["str"], is_Euclid_norm=param._bool["is_Euclidean"], param=param)
		# Record(stat, cut_info, phase)
	elseif mode == "Bin"
		if size(val_init.x, 2) == 1
			new_val_x = zeros(nSite, K)
			for i in 1:nSite
				if val_init.y[i] >= 1
					new_val_x[i, 1:val_init.y[i]] .= 1
				end
			end
			val_init.x = new_val_x
		end
		cut_info, _, _ = BuildCuts_Bin(val_init, mgclp, phase, CutVector, nClient, nSite, dictF, indIs, F;
			cutM = param._bool["cutM"], cutP = param._bool["cutP"], is_Euclid_norm = param._bool["is_Euclidean"])
		Record(stat, cut_info, phase)
		SubmitCuts_LP(model, CutVector)
	end

	duration = time() - start


	# @printf("\nInitialCuts: %.2f sec\n\n", duration)

	return duration
end

function BuildCuts(val, mgclp, phase::String, CutVector, CutVectorLocal, nClient, nSite, dictF, indIs, LnFbar, F;
	cutM = false, cutP = false, cutF = false, cutLocal = false, str = false, is_Euclid_norm = false, isprint = false, lb_y = nothing, param = nothing, val_stable = nothing, lambda = 0.5, which_first = "cutF",
	vec_cutM = nothing, vec_cutP = nothing, model = nothing, is_lazy = false)


	# is_Euclid_norm = true

	CriticalK = GetCriticalK(val.x, indIs)
	val_y_round = round.(Int, val.y)
	PhiP = GetProduction(nSite, nClient, val_y_round, F)

	cut_info = Dict(cutname => Stat_Cut([phase]) for cutname in ["max", "prod_oa", "prod_sm_fixed", "prod_sm_C", "prod_local", "facet"])

	PhiP_lb = zeros(nClient)
	if cutLocal && !isnothing(lb_y)
		PhiP_lb = GetProduction(nSite, nClient, lb_y, F)
	end

	if cutF
		ki_lifted = ones(Int, nSite)
		ind_y_nz, _ = findnz(sparse(val.y))
		for i in ind_y_nz
			if val.x[i] < EPS
				continue
			end
			ki_lifted[i] = floor(val.y[i] / val.x[i])
		end
	end


	arr_cutname = String[]

	if which_first == "cutF"
		if cutF
			push!(arr_cutname, "prod_sm_fixed")
		end
		if cutP
			push!(arr_cutname, "prod_oa")
		end
	else
		if cutP
			push!(arr_cutname, "prod_oa")
		end
		if cutF
			push!(arr_cutname, "prod_sm_fixed")
		end
	end

	for j in 1:nClient

		indy = copy(dictF[j][-1])
		indx_const = copy(dictF[j][1])



		# the dictionary that constains constraints concerning to etaP, violated by current point

		arr_cut_prod = Vector{Tuple{String, Coef, Float64, Float64}}()
		# the flag standing for whether cutF is in coef_dict, if flag is true, we don't need to calculate cutP and check whether cutP is violated
		if cutM == true
			start = time()
			cutname = "max"
			vio, Euclid_norm, coef = -1.0, 1.0, nothing
			coef, rhs = compute_coef_cutM(nClient, nSite, CriticalK[j], indIs[:, j], F[:, j], val.x)
			vio = val.etaM[j] - rhs
			if vio > EPS
				mycut, _, num_nonzero_cutM = calculate_violation(coef, mgclp.x, mgclp.y, mgclp.etaM[j]; is_num_nonzero = true)
				consM = @build_constraint(mycut / Euclid_norm <= 0)
				push!(CutVector, consM)
				cut_info[cutname].Num[phase] += 1
				cut_info[cutname].AverNNZ[phase] += num_nonzero_cutM # not an average yet
				if !isnothing(vec_cutM) && !isnothing(model)
					push!(vec_cutM[j], (@constraint(model, mycut / Euclid_norm <= 0), coef))
				end
			end
			duration = time() - start
			cut_info[cutname].Time[phase] += duration
		end
		flag_cutP = false
		flag_facet = false
		for cutname in arr_cutname
			if flag_cutP && which_first != "both"
				continue
			end

			start = time()
			coef, vio, Euclid_norm = nothing, -1, 1.0

			if cutname == "prod_oa"
				coef = compute_coef_cutP(nClient, nSite, indy, indx_const, LnFbar, PhiP, val.etaP[j], val.x, val.y, val_y_round, j; str = str, flag = param._bool["is_right_cutP"])
			elseif cutname == "prod_sm_fixed"
				sum_x_Ifull = sum(val.x[indx_const])
				if sum_x_Ifull - val.etaP[j] > EPS
					continue
				end
				# coef = compute_coef_cut_lifted_k(nClient, nSite, F[:, j], val.x, val.y, ki_lifted, indy, indx_const)
				# vio, Euclid_norm, _ = calculate_violation(coef, val.x, val.y, val.etaP[j]; is_Euclid_norm = is_Euclid_norm)
				# if vio < EPS && param._bool["cutC"]
				# coef = compute_coef_cut_lifted_C(nClient, nSite, val.x, val.y, indy, indx_const, F, j; isprint = isprint)

				coef, flag_facet =
					compute_coef_cut_lifted_C(nClient, nSite, val.x, val.y, indy, indx_const, F, j; isprint = isprint, ki_lifted = ki_lifted, which_perm = param._string["which_perm"], is_local_search = param._bool["is_local_search"], K = param._int["K"])
				# vio, Euclid_norm, _ = calculate_violation(coef, val.x, val.y, val.etaP[j]; is_Euclid_norm = is_Euclid_norm)
				# if vio > EPS 
				# 	@info vio 
				# end
				# coef_k = compute_coef_cut_lifted_C(nClient, nSite, val.x, val.y, indy, indx_const, F, j; isprint = isprint, ki_lifted=ki_lifted, which_perm = "null")
				# vio_k, Euclid_norm, _ = calculate_violation(coef_k, val.x, val.y, val.etaP[j]; is_Euclid_norm = is_Euclid_norm)
				# if  vio < vio_k - EPS && vio_k > EPS 
				# 	_ = compute_coef_cut_lifted_C(nClient, nSite, val.x, val.y, indy, indx_const, F, j; isprint = true, ki_lifted=ki_lifted, which_perm = param._string["which_perm"])
				# 	_ = compute_coef_cut_lifted_C(nClient, nSite, val.x, val.y, indy, indx_const, F, j; isprint = true, ki_lifted=ki_lifted, which_perm = "null")

				# 	PrintCoef2(coef, str = "coef_new")
				# 	PrintCoef2(coef_k, str = "coef_old")
				# 	@info "vio_old: $vio_k, vio_new: $vio, val_eta: $(val.etaP[j])"
				# 	@info "indy:", indy
				# 	@info "prob[indy]:",  F[indy, j]
				# 	@info "val_y[indy]:", val.y[indy]
				# 	@info "val_x[indy]:", val.x[indy]
				# 	@info "indx_const:", indx_const
				# 	@info "val_x[indx_const]", val.x[indx_const]

				# 	# @assert(false)
				# end
				cutname = "prod_sm_C"
				# end
			end

			if !isnothing(coef)
				vio, Euclid_norm, _ = calculate_violation(coef, val.x, val.y, val.etaP[j]; is_Euclid_norm = is_Euclid_norm)
				if vio > EPS
					flag_cutP = true
					# to be revised later
					push!(arr_cut_prod, (cutname, coef, vio, Euclid_norm))
				end
			end
			duration = time() - start
			cut_info[cutname].Time[phase] += duration
		end
		# for the product term, at most one cut (for each customer) is added at each iteration 
		if isempty(arr_cut_prod)
			continue
		end

		max_vio = 0
		coef_prod, Euclid_norm_prod, cutname_prod = nothing, 1, ""

		for (cutname, coef, vio, Euclid_norm) in arr_cut_prod
			if vio > max_vio + EPS
				coef_prod, Euclid_norm_prod, cutname_prod = coef, Euclid_norm, cutname
				max_vio = vio
			end
		end

		if coef_prod !== nothing
			mycut, _, num_nonzero_prod = calculate_violation(coef_prod, mgclp.x, mgclp.y, mgclp.etaP[j]; is_num_nonzero = true)
			consProd = @build_constraint(mycut / Euclid_norm_prod <= 0)
			if !isnothing(vec_cutP) && !isnothing(model)
				push!(vec_cutP[j], (@constraint(model, mycut / Euclid_norm <= 0), coef_prod))
			end
			if contains(cutname_prod, "local")
				push!(CutVectorLocal, consProd)
			else
				push!(CutVector, consProd)
			end
			cut_info[cutname_prod].Num[phase] += 1
			cut_info[cutname_prod].AverNNZ[phase] += num_nonzero_prod

			# if cutname_prod == "prod_sm_C"
			# 	@info flag_facet, !isempty(indx_const)
			# end
			if cutname_prod == "prod_sm_C" && flag_facet && !isempty(indx_const)
				cut_info["facet"].Num[phase] += 1
			end
		end
	end
	# @info num, num_total, num / num_total, phase
	nCutM, nCutP, nCutF, nCutC = cut_info["max"].Num[phase], cut_info["prod_oa"].Num[phase], cut_info["prod_sm_fixed"].Num[phase], cut_info["prod_sm_C"].Num[phase]
	return cut_info, nCutM, nCutP, nCutC
end
