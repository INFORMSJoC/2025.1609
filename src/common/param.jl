"""
	METHOD_PRESETS

The settings of the paper, each expanded into the switches that define it.
Passing `methods=<name>` applies one of them; a switch that is also given on the
command line keeps the value of the command line.

`BnC` stands for the `B&C` of the paper. `cutF=1` always comes with the local
search of the coefficient heuristic of the lifted subadditive inequalities on.
"""
const METHOD_PRESETS = Dict{String, Dict{String, Any}}(
	"BnC-B" => Dict("mode" => "Bin"),
	"bBnC-I" => Dict("mode" => "Int", "str" => false, "cutF" => false, "is_local_search" => false),
	"bBnC-I+E" => Dict("mode" => "Int", "str" => true, "cutF" => false, "is_local_search" => false),
	"bBnC-I+L" => Dict("mode" => "Int", "str" => false, "cutF" => true, "which_perm" => "clever", "is_local_search" => true),
	"bBnC-I+E+L" => Dict("mode" => "Int", "str" => true, "cutF" => true, "which_perm" => "clever", "is_local_search" => true),
)


struct Param
	"""
	the structure to store command-line arguments by their type
	"""
	_bool::Dict{String, Bool}
	_int::Dict{String, Int}
	_float::Dict{String, Float64}
	_string::Dict{String, String}

	function Param()
		"""
		the function to initialize an object of structure Param
		"""
		dict_bool = Dict(
			# parameter(s) on cuts
			"is_Euclidean" => 0,    # whether we use Euclidean distance when determining the most violated cuts
			"cutM" => 1,   # whether we use the 'max' cuts in Lazy Constraint callback and User Cut callback
			"cutP" => 0,   # whether we use the 'prod-oa' (outer approximation) cuts in Lazy Constraint callback and User Cut callback
			# "cutC" => 0,   # whether we use the 'prod-cont' (outer approximation) cuts in Lazy Constraint callback and User Cut callback
			# "MIR" => 0,    # whether we use the 'prod-oa-mir' (apply MIR on prod-oa) cuts in Lazy Constraint callback, User Cut callback and initial cuts
			"str" => 0,    # whether we strengthen coefficients of the 'prod-oa' cuts
			"cutF" => 0,   # whether we use the 'prod-sm-fixed' (substitute variables yi by xi + ti and fix some xi to its upper bound 1) cuts in Lazy Constraint callback and User Cut callback
			"cutC" => 0,   # whether we use the 'prod-sm-fixed' (substitute variables yi by xi + ti and fix some xi to its upper bound 1) cuts in Lazy Constraint callback and User Cut callback
			"cutLocal" => 0,
			"cutM_stable" => 0,
			"cutP_stable" => 0,
			"cutF_stable" => 0,
			"stable_root" => 0,
			"is_root" => 0,
			"is_right_cutP" => 1,
			"two_phase" => 0,
			"pmed" => 0,
			"is_local_search" => 1,
			"am_start_heuristic" => 0,
			"am_local_search" => 1,
			"am_callback_heuristic" => 0,

			# parameter(s) on initial cuts
			"init_val_greedy" => 1,     # whether we use the solution, found by greedy algorithm at the preprocessing phase, to generate initial cuts
			"cutM_init" => 1,   # whether we use the 'max' cuts as initial cuts / constriants
			"cutP_init" => 0,  # whether we use the 'prod-oa' cuts as initial cuts / constriants
			"cutF_init" => 0,   # whether we use the 'prod-sm-fixed' cuts as initial cuts / constriants
			"cutC_init" => 0,  # whether we use the 'prod-oa' cuts as initial cuts / constriants


			# parameter(s) on preprocessing
			"pre" => 0,       # whether we use preprocess techniques to strengthen the upper bounds of integer variables yi, i ∈ [n] 
			"ubstr" => 0,     # whether we are at a sub-process of solving the LP relaxation of MGCLP to get tighter upper bounds of variables yi
			"is_silent" => 0, # whether we print the log on the screen
			"init" => 0,

			# parameter(s) on setting start value
			"is_start" => 0,  # whether we set start values for MGCLP

			# parameter(s) on building the model
			# "no_imply_ub" => 0

			"mycut" => 0,
			"comp" => 0,
			"cutF_wrong" => 0,
			"init_cutF_zero" => 0,
			"colocation" => 1,
		)
		dict_int = Dict(
			"K" => 0,
			"type_delta" => 0,
			"init" => 0,
			"nsepa" => 1,
			"am_callback_node_space" => 50,
			"mixture_seed" => 1,
			"node_space" => -1,
			"strF" => 0,  # whether we strengthen coefficients of the 'prod-fixed' cuts
			"nodelimit" => -1,  # parameter of the node limit of optimization
		)
		dict_float = Dict(
			"theta" => 0.0,      # the value of parameter theta
			"r" => 0,            # the value of maximum distance of taking probability as 1
			"R" => 0,            # the value of minimum distance of taking probability as 0
			"gap" => 0.0,        # parameter of the gap limit of optimizaiton
			"timelimit" => 3600, # parameter of the time limit of optimization
			"EPS" => 1e-6,
			"EPS_FRAC" => 1e-6,
			"mixture_low_share" => 0.8,
			"mixture_low_min" => 0.001,
			"mixture_low_max" => 0.01,
			"mixture_high_min" => 0.9,
			"mixture_high_max" => 0.99,
		)
		dict_string = Dict(
			"methods" => "",  # the setting of the paper to run, e.g. bBnC-I or bBnC-I+E+L
			"mode" => "",     # to select the formulation of MGCLP -- Bin or Int
			"fn_data" => "",  # the filename that stores a solution of MGCLP 
			"fn" => "",       # the filename of pmed data -- pmedxx.txt
			"fn_w" => "",     # the filename of weights w
			"fn_sol" => "",
			"msg" => "default",       # the message that decides the pattern of adding User Cuts -- default, no_prod, none
			"solver" => "cplex",
			"which_first" => "cutF",
			"init_scheme" => "cutP_heur",
			"which_perm" => "clever",
			"prob_func" => "linear",
		)
		new(copy(dict_bool), copy(dict_int), copy(dict_float), copy(dict_string))
	end

	function Param(_param::Param)
		"""
		the function to initialize an object of structure Param by another object
		"""
		new(copy(_param._bool), copy(_param._int), copy(_param._float), copy(_param._string))
	end
end


function apply_method!(param::Param, name::String, given::Set{String})
	"""
	the function to expand a method preset of the paper into its switches
	"""
	if !haskey(METHOD_PRESETS, name)
		error("methods=$(name) is unknown; the method names are $(join(sort!(collect(keys(METHOD_PRESETS))), ", "))")
	end
	for (key, value) in METHOD_PRESETS[name]
		if key in given
			continue
		elseif haskey(param._bool, key)
			param._bool[key] = value
		elseif haskey(param._int, key)
			param._int[key] = value
		elseif haskey(param._float, key)
			param._float[key] = value
		elseif haskey(param._string, key)
			param._string[key] = value
		else
			error("methods=$(name) sets a parameter that does not exist: $(key)")
		end
	end
	return param
end


function read_param(ARGS)
	param = Param()
	given = Set{String}()

	if length(ARGS) >= 1
		for ind in 1:(length(ARGS))
			paraName, paraVal = split(ARGS[ind], '=', keepempty = false)
			push!(given, paraName)
			if haskey(param._bool, paraName)
				param._bool[paraName] = parse(Bool, paraVal)
			elseif haskey(param._int, paraName)
				param._int[paraName] = parse(Int, paraVal)
			elseif haskey(param._float, paraName)
				param._float[paraName] = parse(Float64, paraVal)
			elseif haskey(param._string, paraName)
				param._string[paraName] = paraVal
			else
				@printf("Undefined parameter: %s!\n", ARGS[ind])
			end
		end
	end

	if param._string["methods"] != ""
		apply_method!(param, param._string["methods"], given)
	end


	r = param._float["r"]
	R = param._float["R"]
	theta = param._float["theta"]
	fn = param._string["fn"]
	fn_weight = param._string["fn_w"]
	prob_func = param._string["prob_func"]

	if fn_weight != ""
		w = ReadWeights(fn_weight)
	else
		w = nothing
	end

	K = param._int["K"]
	if K != 0
		_, Dist = Read_Pmed_Uncapacited(fn)
	else
		K, Dist = Read_Pmed_Uncapacited(fn)
	end
	param._int["K"] = K
	F, numC1, numCP = TransformIntoF(Dist, r, R;
		EPS=param._float["EPS"],
		prob_func=prob_func,
		mixture_low_share=param._float["mixture_low_share"],
		mixture_low_min=param._float["mixture_low_min"],
		mixture_low_max=param._float["mixture_low_max"],
		mixture_high_min=param._float["mixture_high_min"],
		mixture_high_max=param._float["mixture_high_max"],
		mixture_seed=param._int["mixture_seed"])         # coverage rates
	nSite, nClient = size(F)
	@printf("%-40s%d\n", "|V|", nSite)
	@printf("%-40s%d\n", "K", K)
	@printf("%-40s%.2f\n", "theta", theta)
	@printf("%-40s%d\n", "r", r)
	@printf("%-40s%d\n", "R", R)
	@printf("%-40s%s\n", "prob_func", prob_func)
	if lowercase(prob_func) in ["facility_mixture", "facility_mix", "low_high"]
		@printf("%-40s%.6f\n", "mixture_low_share", param._float["mixture_low_share"])
		@printf("%-40s[%.6f, %.6f]\n", "mixture_low_interval", param._float["mixture_low_min"], param._float["mixture_low_max"])
		@printf("%-40s[%.6f, %.6f]\n", "mixture_high_interval", param._float["mixture_high_min"], param._float["mixture_high_max"])
		@printf("%-40s%d\n", "mixture_seed", param._int["mixture_seed"])
	end
	if haskey(LOGIT_QUADRATIC_PROFILES, lowercase(prob_func))
		alpha, beta, gamma = GetLogitQuadraticProfile(prob_func)
		@printf("%-40s(%.0f, %.0f, %.0f)\n", "(alpha,beta,gamma)", alpha, beta, gamma)
	end
	@printf("%-40s%d\n", "#C1", numC1)
	@printf("%-40s%d\n", "#CP", numCP)
	@printf("\n")

	@printf("@Parameters: \n")
	for key_i in sort!(collect(keys(param._bool)))
		@printf("%-40s%s\n", key_i, param._bool[key_i])
	end
	@printf("%-40s%s\n", "mode", param._string["mode"])
	@printf("\n")

	for key_i in sort!(collect(keys(param._int)))
		if key_i == "K"
			continue
		end
		@printf("%-40s%d\n", key_i, param._int[key_i])
	end
	@printf("\n")

	for key_i in sort!(collect(keys(param._float)))
		if key_i in ["r" "R" "theta"]
			continue
		end
		if key_i == "EPS"
			@printf("%-40s%.6f\n", key_i, param._float[key_i])
		else
			@printf("%-40s%.2f\n", key_i, param._float[key_i])
		end
	end
	@printf("\n")

	if isapprox(param._float["theta"], 1.0; atol = 1e-6)
		param._bool["cutP"] = false
		param._bool["cutF"] = false
	end

	#for i in 1:size(F,1)
	#   @info F[i,:]
	#end
	return F, theta, K, param
end
