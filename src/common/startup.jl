
using Printf
using JuMP
using DelimitedFiles
using Random
using MathOptInterface: MathOptInterface
const MOI = MathOptInterface

is_CPLEX = 1

using CPLEX
# if @isdefined(is_COPT)
# 	using COPT
# end
# if @isdefined(is_GUROBI)
# 	using Gurobi
# end
# if @isdefined(is_HIGHS)
# 	using HiGHS
# end
# if @isdefined(is_CPLEX)
# 	using CPLEX
# end


using Logging: with_logger, global_logger, LogLevel, ConsoleLogger
using SparseArrays


mutable struct MGCLP
	"""
	the structure to store variables or the value of variables of MGCLP 
	"""
	x::Any
	y::Any
	etaM::Any
	etaP::Any
	x_var::Any

	MGCLP(x, y, etaM, etaP) = new(x, y, etaM, etaP, nothing)
	MGCLP(x, y, etaM, etaP, x_var) = new(x, y, etaM, etaP, x_var)
end

function value_or_constant(x)
	return x isa Number ? x : value(x)
end

function callback_value_or_constant(cb_data, x)
	return x isa Number ? x : callback_value(cb_data, x)
end

function value_array(x)
	return map(value_or_constant, x)
end

function callback_value_array(cb_data, x)
	return map(xi -> callback_value_or_constant(cb_data, xi), x)
end

function set_start_value_x!(mgclp::MGCLP, val_x)
	if isnothing(mgclp.x_var)
		set_start_value.(mgclp.x, val_x)
	elseif mgclp.x_var isa AbstractDict
		for (ind, var) in mgclp.x_var
			set_start_value(var, val_x[ind...])
		end
	else
		set_start_value.(mgclp.x_var, val_x)
	end
end

function set_binary_x!(mgclp::MGCLP)
	if isnothing(mgclp.x_var)
		set_binary.(mgclp.x)
	elseif mgclp.x_var isa AbstractDict
		set_binary.(values(mgclp.x_var))
	else
		set_binary.(mgclp.x_var)
	end
end

function select_solver(solver::String; threadNumber::Int = -1, seed::Int = -1, timelimit::Number = 7200, nodelimit::Int = -1, gap::Float64 = 0.0)

	solver = lowercase(solver)
	if solver == "gurobi"
		model = Model(Gurobi.Optimizer)
	elseif solver == "copt"
		model = Model(COPT.Optimizer)
	elseif solver == "highs"
		model = Model(HiGHS.Optimizer)
	elseif solver == "cplex"
		model = direct_model(CPLEX.Optimizer())
	end


	set_time_limit_sec(model, timelimit)

	# mip relative gap
	if solver == "gurobi"
		set_optimizer_attribute(model, "MIPGap", gap)
	elseif solver == "copt"
		set_optimizer_attribute(model, "RelGap", gap)
	elseif solver == "highs"
		set_optimizer_attribute(model, "mip_rel_gap", gap)
	elseif solver == "cplex"
		set_optimizer_attribute(model, "CPXPARAM_MIP_Tolerances_MIPGap", gap)
	end

	# log to console 
	if solver == "gurobi" || solver == "copt"
		set_optimizer_attribute(model, "LogToConsole", 1)
	elseif solver == "highs"
		set_optimizer_attribute(model, "log_to_console", true)
		# elseif solver == "cplex"
		#     set_optimizer_attribute(model, "log_to_console", true)
	end

	# node limit 
	if nodelimit > 0
		if solver == "gurobi" || solver == "copt"
			set_optimizer_attribute(model, "NodeLimit", nodelimit)
		elseif solver == "highs"
			set_optimizer_attribute(model, "mip_max_nodes", nodelimit)
		elseif solver == "cplex"
			set_optimizer_attribute(model, "CPX_PARAM_NODELIM", nodelimit)
		end
	end

	# number of threads
	if threadNumber > 0
		if solver == "gurobi" || solver == "copt"
			set_optimizer_attribute(model, "Threads", threadNumber)
		elseif solver == "highs"
			set_optimizer_attribute(model, "threads", threadNumber)
		elseif solver == "cplex"
			set_optimizer_attribute(model, "CPXPARAM_Threads", threadNumber)
		end
	end

	# random seed
	if seed > -1
		if solver == "gurobi"
			set_optimizer_attribute(model, "Seed", seed)
		elseif solver == "copt"
		elseif solver == "highs"
			set_optimizer_attribute(model, "random_seed", seed)
		elseif solver == "cplex"
			set_optimizer_attribute(model, "CPXPARAM_RandomSeed", seed)
		end
	end

	return model
end

function SetStartValue(fn_data, mgclp, F, indIs, mode = "Int")

	start = time()

	time1, start_val = getstartvalue(fn_data, F, indIs, mode)
	@info time1

	set_start_value_x!(mgclp, start_val.x)
	set_start_value.(mgclp.etaM, start_val.etaM)
	set_start_value.(mgclp.etaP, start_val.etaP)

	if mode == "Int"
		set_start_value.(mgclp.y, start_val.y)
	end

	duration = time() - start
	return duration, start_val
end


function CalcObj(val_etaM, val_etaP, theta, w = nothing)
	if w === nothing
		obj = theta * sum(val_etaM) + (1 - theta) * sum(val_etaP)
	else
		obj = theta * sum(val_etaM[j] * w[j] for j in 1:nClient) + (1 - theta) * sum(val_etaP[j] * w[j] for j in 1:nClient)
	end
	return obj
end

function PrintInfos(model::Model, param; is_LP::Bool = false)
		if !is_LP
			@printf("Solve Time: %.2f\n", solve_time(model))
			@printf("Number of Nodes: %d\n", node_count(model))
			@printf("Termination Status: %s\n", termination_status(model))
		end
end

	function PrintSol(model, mode, nSite, indIs, F, theta)
		pstatus = primal_status(model)
		sol, dict_sol = nothing, Dict{Int, Vector{Int}}()
		if pstatus == MOI.FEASIBLE_POINT
			val_x = value_array(model[:x])
			val_x = round.(val_x)
			if haskey(model, :y)
				val_y = value.(model[:y])
				val_y = round.(val_y)
			else
				val_y = zeros(nSite)
				for i in 1:nSite
					val_y[i] = sum(val_x[i, :])
				end
			end
			val_etaM = value.(model[:etaM])
			val_etaP = haskey(model, :etaP) ? value.(model[:etaP]) : zeros(nClient)
			sol = MGCLP(round.(Int, val_x), round.(Int, val_y), val_etaM, val_etaP)
			for i in 1:nSite
				yi = round(val_y[i])
				if yi > 0
					if !in(yi, keys(dict_sol))
						dict_sol[yi] = [i]
					else
						append!(dict_sol[yi], i)
					end
				end
			end
		end
		counter = 0
		vec_keys = collect(keys(dict_sol))
		sort!(vec_keys)
		for k in vec_keys
			vec_facility_k = sort!(dict_sol[k])
			@printf("%d: %d", k, vec_facility_k[1])
			for i in vec_facility_k[2:end]
				@printf(", %d", i)
			end
			@printf("\n")
		end
		val_etaM_calc, val_etaP_calc = GetEtaFromScratch(sol.x, sol.y, F, indIs, nSite, nClient, mode)
		@printf("Objective Value (calc): %.6f\n", CalcObj(val_etaM_calc, val_etaP_calc, theta))
		@printf("sum_etaM = %.6f / %.6f\n", sum(sol.etaM), sum(val_etaM_calc))
		@printf("sum_etaP = %.6f / %.6f\n", sum(sol.etaP), sum(val_etaP_calc))
		# Compute co-location stats
		nL = 0; nCL = 0; mCL = 1
		for k in keys(dict_sol)
			nSites = length(dict_sol[k])
			nL += nSites
			if k > 1
				nCL += nSites
			end
			mCL = max(mCL, k)
		end
		@printf("nL: %d\n", nL)
		@printf("nCL: %d\n", nCL)
		@printf("mCL: %d\n", mCL)
		return MGCLP(sol.x, sol.y, val_etaM_calc, val_etaP_calc)
	end




function GetSolFromSet(sol_set::Dict{Int, Int}, nSite, nClient, F, K, indIs; mode = "Int")
	val_y = zeros(Int, nSite)
	for i in keys(sol_set)
		val_y[i] = sol_set[i]
	end
	if mode == "Bin"
		val_x = zeros(Int, nSite, K)
		for i in collect(keys(sol_set))
			for k in 1:val_y[i]
				val_x[i, k] = 1
			end
		end
		for i in keys(sol_set)
			val_x[i, 1:sol_set[i]] .= 1
		end
	elseif mode == "Int"
		val_x = zeros(Int, nSite)
		val_x[filter(i -> val_y[i] > 0, 1:nSite)] .= 1
		vec = filter(i -> val_y[i] > 0, 1:nSite)
	end
	val_etaM, val_etaP = GetEtaFromScratch(val_x, val_y, F, indIs, nSite, nClient, mode)
	sol = MGCLP(val_x, val_y, val_etaM, val_etaP)

	return sol
end


struct Stat_Cut
	"""
	the structure to store statistical results concerning cuts
	"""
	Phase::Vector{String}            # 
Num::Dict{String, Int}
	Time::Dict{String, Float64}
	AverNNZ::Dict{String, Float64}

	function Stat_Cut(arr_phase::Vector{String})
		# arr_phase = ["init", "rLC", "rUC", "sLC", "sUC"] # subnode LC , root node LC
		new(arr_phase, Dict(phase => 0 for phase in arr_phase), Dict(phase => 0 for phase in arr_phase), Dict(phase => 0 for phase in arr_phase))
	end

	function Stat_Cut(phase::String, num::Int, time::Float64, nnz)
		arr_phase = [phase]
		new(arr_phase, Dict(phase => num), Dict(phase => time), Dict(phase => nnz))
	end
end

struct Stat
	Phase::Vector{String}
	CutName::Vector{String}
	CutInfo::Dict{String, Stat_Cut}
	Round::Dict{String, Int}
	Sol::Dict{String, Union{MGCLP, Nothing}}
	Bound::Dict{String, Float64}
	Others::Dict{String, Any}

	function Stat()
		arr_phase = ["LP", "init", "rLC", "rUC", "sLC", "sUC"] # subnode LC , root node LC
		arr_cutname = ["max", "prod_oa", "prod_sm_fixed", "prod_bin", "prod_local", "prod_sm_C", "facet"]
		cutinfo = Dict(each_cutname => Stat_Cut(arr_phase) for each_cutname in arr_cutname)
		roundinfo = Dict(phase => 0 for phase in arr_phase)
		roundinfo["lp_not_improved"] = 0
		roundinfo["last_num_node"] = 0
		roundinfo["num_round"] = 0
		roundinfo["count_down"] = 0
		roundinfo["count_up"] = 0
		sol = Dict{String, MGCLP}()
		bound = Dict(
			"root_best_integer" => 0.0,
			"root_best_bound" => 0.0,
			"best_bound" => 0.0,
			"best_integer" => 0.0,
		)
		others = Dict()
		new(arr_phase, arr_cutname, cutinfo, roundinfo, sol, bound, others)
	end
end

function PrintStatCut(stat_cut::Stat_Cut)
	for phase in stat_cut.Phase
		@printf("%5s %5d / %4.2f / %4.2f ", "[" * phase * "]", stat_cut.Num[phase], stat_cut.Time[phase], stat_cut.AverNNZ[phase])
	end
	@printf("\n")
end

	function PrintStat(model, stat::Stat; obj = nothing)
		if obj !== nothing
			# CutInfo
			@printf("\nCutInfo: [phase] num / time (sec) / aver. num_nonzero\n")
			for cutname in stat.CutName
				@printf("%-16s", cutname)
				PrintStatCut(stat.CutInfo[cutname])
			end
			@printf("Separation Round:   ")
			for phase in stat.Phase
				@printf("[%s] %d  ", phase, stat.Round[phase])
			end
			@printf("\n")
			@printf("Root Best Bound %f\n", stat.Bound["root_best_bound"])
			@printf("Root Best Integer: %f\n", stat.Bound["root_best_integer"])
			@printf("Best Bound: %f\n", stat.Bound["best_bound"])
			@printf("Best Integer: %f\n", stat.Bound["best_integer"])
		end
	end
