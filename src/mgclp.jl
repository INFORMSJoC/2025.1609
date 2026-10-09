# example for pmed data

# julia mgclp.jl ./data/pmed1.txt 
# const EPS = 1e-4
include("./common/startup.jl")
include("./common/readdata.jl")
include("./common/param.jl")
include("./common/cuts_common.jl")

include("./mgclp/model.jl")
include("./mgclp/preprocess.jl")


include("./mgclp/cuts.jl")


function PhaseOne(model, mgclp, param, stat, nClient, nSite, dictF, indIs, LnFbar, F)
	phase = "LP"
	iter, num_cut_vio = 1, 0
	set_silent(model)
	timelimit = param._float["timelimit"]
	# vec_cutM = fill(Vector{Tuple{ConstraintRef,Coef}}(), nClient)
	# vec_cutP = fill(Vector{Tuple{ConstraintRef,Coef}}(), nClient)
	# @info typeof(vec_cutM)
	# @info typeof(vec_cutM[1])

	val_callback = nothing
	# @info "length cutM: $(sum(length.(vec_cutM)))"
	# @info "length cutP: $(sum(length.(vec_cutP)))"
	# @assert(false)


	# vec_cutP and vec_cutM are for eliminate the redundant cuts at the end of the first stage 
	vec_cutP = Vector{Vector{Tuple{ConstraintRef, Coef}}}(undef, nClient)
	vec_cutM = Vector{Vector{Tuple{ConstraintRef, Coef}}}(undef, nClient)
	for j in 1:nClient
		vec_cutM[j] = Vector{Tuple{ConstraintRef, Coef}}()
		vec_cutP[j] = Vector{Tuple{ConstraintRef, Coef}}()
	end


	while iter == 1 || num_cut_vio > 0
		CutVector = Vector{ScalarConstraint{AffExpr, MathOptInterface.LessThan{Float64}}}(undef, 1)
		CutVectorLocal = Vector{ScalarConstraint{AffExpr, MathOptInterface.LessThan{Float64}}}(undef, 1)
		start_LP = time()
		optimize!(model)
		PrintInfos(model::Model, param; is_LP = true)
		set_time_limit_sec(model, timelimit)

		val_etaM = value.(mgclp.etaM)
		val_etaP = value.(mgclp.etaP)
		val_x = value_array(mgclp.x)
		val_y = !isnothing(mgclp.y) ? value.(mgclp.y) : [sum(val_x[i, :]) for i in 1:nSite]

		val_callback = MGCLP(val_x, val_y, val_etaM, val_etaP)

		cut_info = Dict(cutname => Stat_Cut([phase]) for cutname in stat.CutName)
		_cutM, _cutP, _cutF = param._bool["cutM"], param._bool["cutP"], param._bool["cutF"]
		# @info phase, num_node, param._int["node_space"], _cutP
		mode = param._string["mode"]
		cut_info = Dict()
		if mode == "Int"
			val_stable, lambda = nothing, 1
			cut_info, nCutM, nCutP, nCutF = BuildCuts(val_callback, mgclp, phase, CutVector, CutVectorLocal, nClient, nSite, dictF, indIs, LnFbar, F;
				cutM = _cutM, cutP = _cutP, cutF = _cutF, which_first = param._string["which_first"],# lb_y=lb_y,
				str = param._bool["str"], is_Euclid_norm = param._bool["is_Euclidean"], param = param, val_stable = val_stable, lambda = lambda,
				vec_cutM = vec_cutM, vec_cutP = vec_cutP, model = model)
		elseif mode == "Bin"
			cut_info, nCutM, nCutP = BuildCuts_Bin(val_callback, mgclp, phase, CutVector, nClient, nSite, dictF, indIs, F;
				cutM = _cutM, cutP = _cutP, is_Euclid_norm = param._bool["is_Euclidean"])
		end
		println("Iter $iter")
		duration = time() - start_LP
		timelimit -= duration
		@printf("Duration: %.2f sec Time Left: %.2f sec\n", duration, timelimit)
		num_cut_vio = length(CutVector) - 1
		for each_key in keys(cut_info)
			num_cut = cut_info[each_key].Num[phase]
			if num_cut > 0
				@printf("%s %d\n", each_key, cut_info[each_key].Num[phase])
			end
		end
		@printf("\n")
		# val_etaM_calc, val_etaP_calc = GetEtaFromScratch(round.(Int, val_callback.x), round.(Int, val_callback.y), F, indIs, nSite, nClient, mode)
		# @printf("Objective Value (calc): %.6f\n", CalcObj(val_etaM_calc, val_etaP_calc, theta))
		# SubmitCuts_LP(model, CutVector)
		Record(stat, cut_info, phase)
		iter += 1
		# @info "length cutM: $(sum(length.(vec_cutM)))"
		# @info "length cutP: $(sum(length.(vec_cutP)))"
	end

	# remove the unsaturated constraints
	num_delP = zeros(Int, nClient)
	num_delM = zeros(Int, nClient)
	for j in 1:nClient
		for (cons, coef) in vec_cutM[j]
			if is_valid(model, cons)
				vio, _, _ = calculate_violation(coef, val_callback.x, val_callback.y, val_callback.etaM[j]; is_num_nonzero = true)
				if vio < -EPS
					JuMP.delete(model, cons)
					num_delM[j] += 1
				end
			end
		end
		for (cons, coef) in vec_cutP[j]
			if is_valid(model, cons)
				vio, _, _ = calculate_violation(coef, val_callback.x, val_callback.y, val_callback.etaP[j]; is_num_nonzero = true)
				if vio < -EPS
					JuMP.delete(model, cons)
					num_delP[j] += 1
				end
			end
		end
	end
	


	set_binary_x!(mgclp)
	if !isnothing(mgclp.y)
		set_integer.(mgclp.y)
	end
	unset_silent(model)
end

"""
   MGCLP(F, theta, K; mode="Bin", gap=0.0, param=nothing, fn_data="", w=nothing, is_submgclp=false, nodelimit=Inf)
Brief:
   build and solve the multiple gradual covering location problem 
Param:
- F::Matrix{Float64}          the probability matrix
- theta::Float64              an association factor dipicting the correlation between proportion of cover
- K::Int64                    number of facilities to be built
- mode::String                the formulation adopted to solve MGCLP
- gap::

Return:

"""


function MGCLP_Main_Func(F, theta, K; param = nothing, fn_data = "", w = nothing, is_submgclp = false, sol_pmed = nothing, is_precompile = false)


	mode = param._string["mode"]

	nSite, nClient = size(F)
	if isnothing(w)
		w = ones(nClient)
	end
	# read data
	indIs = GetSortedIndex(F; dim = 2)
	dictF, LnFbar = GetDictFacility(F, nSite, nClient)

	stat = Stat()

	vec_sites_closed, vec_sites_UBone = [], []
	ConfinedSitesk = Dict{Int, Int}()

	# construct the model 
	UB = is_submgclp == true ? Dict(i => Float64(nSite) for i in 1:K) : nothing
	UBy = ones(Int, nSite) * K
	val_greedy_y = []
	# Preprocess 
	if param._bool["pre"] == true
		UBy, dictF, val_greedy_y = Preprocess(param, dictF, F, theta, nSite, nClient, K, UBy, w, fn_data)
		dict_sol_greedy = Dict{Int, Int}(i => val_greedy_y[i] for i in 1:nSite if val_greedy_y[i] > 0)
		stat.Sol["greedy"] = GetSolFromSet(dict_sol_greedy, nSite, nClient, F, K, indIs; mode = "Int")
	end
	if param._bool["am_start_heuristic"]
		am_UBy = param._bool["colocation"] ? UBy : ones(Int, nSite)
		stat.Sol["am_start"] = am_start_solution(
			F,
			theta,
			K,
			am_UBy,
			indIs,
			mode;
			local_search = param._bool["am_local_search"],
		)
	end
	if !isnothing(sol_pmed)
		stat.Sol["pmed"] = sol_pmed
	end

	model = select_solver("cplex"; timelimit = param._float["timelimit"], nodelimit = param._int["nodelimit"], gap = param._float["gap"])

	model, mgclp = BuildModel(F, K, theta, w, indIs, model; mode = param._string["mode"], UBy = UBy, dictF = dictF, LnFbar = LnFbar, is_relaxed = param._bool["two_phase"], colocation = param._bool["colocation"])
	if is_precompile
		set_time_limit_sec(model, 40)
		set_silent(model)
	end

	# Set start value
	# stat.Sol["start"] = nothing
	if param._string["fn_sol"] != ""
		# time_start_val, start_val = SetStartValue(fn_data, mgclp, F, indIs, mode)
		dict_start_sol = read_mgclp_solution(param._string["fn"], param._string["fn_sol"], param._float["r"], param._float["R"], param._float["theta"], nSite)
		stat.Sol["start"] = GetSolFromSet(dict_start_sol, nSite, nClient, F, K, indIs; mode = "Int")
		# TimeInfo["SetStartValue"] = time_start_val
	end

	# @info "aha"
	# temp_ind = findnz(sparse(stat.Sol["greedy"].y))[1]
	# @info UBy[temp_ind]

	# find the best solution 
	# if isnothing(stat.Sol["start"])
	#     stat.Sol["fea"] = stat.Sol["greedy"]
	# else
	#     obj_start = CalcObj(stat.Sol["start"].etaM, stat.Sol["start"].etaP, theta)
	#     obj_greedy = CalcObj(stat.Sol["greedy"].etaM, stat.Sol["greedy"].etaP, theta)
	#     stat.Sol["fea"] = obj_start > obj_greedy ? stat.Sol["start"] : stat.Sol["greedy"]
	# end

	best_obj = -1
	for each_key in keys(stat.Sol)
		this_sol = stat.Sol[each_key]
		dict_sol = Dict{Int, Int}(i => round(Int, this_sol.y[i]) for i in 1:nSite if this_sol.y[i] > 0)
		this_sol_new = GetSolFromSet(dict_sol, nSite, nClient, F, K, indIs; mode = mode)
		this_obj = CalcObj(this_sol_new.etaM, this_sol_new.etaP, theta)
		if this_obj > best_obj
			best_obj = this_obj
			stat.Sol["fea"] = this_sol_new
		end
	end
	if haskey(stat.Sol, "fea")
		set_start_value_x!(mgclp, stat.Sol["fea"].x)
		!isnothing(mgclp.y) ? set_start_value.(mgclp.y, stat.Sol["fea"].y) : nothing
		# for i in 1:nSite
		#     if stat.Sol["fea"].y[i] > UBy[i]
		#         @assert(false)
		#     end
		# end
		set_start_value.(mgclp.etaM, stat.Sol["fea"].etaM)
		isnothing(mgclp.etaP) ? nothing : set_start_value.(mgclp.etaP, stat.Sol["fea"].etaP)
		
	end

	if param._bool["init"]
		# add_initial_cuts(model, mgclp, stat, nClient, nSite, dictF, indIs, LnFbar, F, param, K; val_init=stat.Sol["fea"], vec_cutM=vec_cutM, vec_cutP=vec_cutP)
		add_initial_cuts(model, mgclp, stat, nClient, nSite, dictF, indIs, LnFbar, F, param, K; val_init = stat.Sol["fea"])
	end
	# @info "before LP | number of constraints", num_constraints(model; count_variable_in_set_constraints=false)

	if param._bool["two_phase"]
		PhaseOne(model, mgclp, param, stat, nClient, nSite, dictF, indIs, LnFbar, F)
	end
	
	add_callback_cuts(model, mgclp, stat, nClient, nSite, theta, F, indIs, dictF, LnFbar, param; is_submgclp = is_submgclp, UB = UB, sol_greedy = (haskey(stat.Sol, "fea") ? stat.Sol["fea"] : nothing), UBy = UBy)

	param._bool["is_silent"] == true || is_submgclp ? set_silent(model) : nothing



	optimize!(model)


	# if is_submgclp == true
	#     # return UB, solve_time(model)
	# end
	PrintInfos(model, param)
	PrintStat(model, stat; obj = objective_value(model))
	sol = PrintSol(model, mode, nSite, indIs, F, theta)
	return model, sol


	return model, stat, indIs
end

function main()
	# if abspath(PROGRAM_FILE) == @__FILE__
	F, theta, K, param = read_param(ARGS)
	global theta = param._float["theta"]
	global EPS, EPS_FRAC = param._float["EPS"], param._float["EPS_FRAC"]
	global nSite, nClient = size(F)
	global K = param._int["K"]
	sol_pmed = nothing
	if param._bool["pmed"]
		param_pmed = Param(param)
		for each_key in ["cutP" "init" "cutF" "two_phase"]
			param_pmed._bool[each_key] = false
		end
		model_pmed, sol_pmed = MGCLP_Main_Func(F, 1, K; param = param_pmed)
		param._float["timelimit"] = param._float["timelimit"] - solve_time(model_pmed)
	end

	open("/dev/null", "w") do io
		redirect_stdout(io) do
			MGCLP_Main_Func(F, theta, K; param = param, sol_pmed = sol_pmed, is_precompile = true)
		end
	end

	MGCLP_Main_Func(F, theta, K; param = param, sol_pmed = sol_pmed, is_precompile = false)

	# PrintInfos(model, param)
	# PrintStat(stat; obj=objective_value(model))
	# PrintSol(model, param._string["mode"], nSite, indIs)
end

main()
# end
