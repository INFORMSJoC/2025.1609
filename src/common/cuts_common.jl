function SubmitCuts_CB(model, CutVector, cb_data, CB_stage; is_local = false)
	if is_local && CB_stage == "UserCut"
		while length(CutVector) > 1
			cut = pop!(CutVector)
			MyMOIsubmit(model, MOI.UserCut(cb_data), cut)
		end
	else
		Cons = CB_stage == "LazyConstraint" ? MOI.LazyConstraint : MOI.UserCut
		while length(CutVector) > 1
			cut = pop!(CutVector)
			MOI.submit(model, Cons(cb_data), cut)
		end
	end
end

function SubmitCuts_LP(model, CutVector)
	while length(CutVector) > 1
		cut = pop!(CutVector)
		add_constraint(model, cut)
	end
end
function Record(stat::Stat, dict_cutinfo, phase; val = nothing, best_bound = -Inf, best_integer = Inf, node = 0)
	for cutname in stat.CutName
		if haskey(dict_cutinfo, cutname)
			stat_cut = dict_cutinfo[cutname]
			for cut_phase in stat_cut.Phase
				stat.CutInfo[cutname].Num[cut_phase] += stat_cut.Num[cut_phase]
				stat.CutInfo[cutname].Time[cut_phase] += stat_cut.Time[cut_phase]
				if stat_cut.AverNNZ[cut_phase] > 0
					stat.CutInfo[cutname].AverNNZ[cut_phase] = (stat.CutInfo[cutname].AverNNZ[cut_phase] * (stat.CutInfo[cutname].Num[cut_phase] - stat_cut.Num[cut_phase]) + stat_cut.AverNNZ[cut_phase]) / stat.CutInfo[cutname].Num[cut_phase]
				end
			end
		end
	end

	stat.Round[phase] += 1

	if val !== nothing
		stat.Sol["fea"] = val
	end

	if best_integer < best_bound
		stat.Bound["best_bound"] = best_bound
		stat.Bound["best_integer"] = best_integer
		if node <= 3
			stat.Bound["root_best_bound"] = best_bound
			stat.Bound["root_best_integer"] = best_integer
		end
	end
end


"""
lazyconstraint callback
"""
function mysubmit(
	model::CPLEX.Optimizer,
	cb::MOI.LazyConstraint{CPLEX.CallbackContext},
	f::MOI.ScalarAffineFunction{Float64},
	s::Union{
		MOI.LessThan{Float64},
		MOI.GreaterThan{Float64},
		MOI.EqualTo{Float64},
	},
)
	if model.callback_state == CPLEX._CB_USER_CUT
		throw(MOI.InvalidCallbackUsage(MOI.UserCutCallback(), cb))
	elseif model.callback_state == CPLEX._CB_HEURISTIC
		throw(MOI.InvalidCallbackUsage(MOI.HeuristicCallback(), cb))
	elseif !iszero(f.constant)
		throw(
			MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(
				f.constant,
			),
		)
	end
	indices, coefficients = CPLEX._indices_and_coefficients(model, f)
	sense, rhs = CPLEX._sense_and_rhs(s)
	ret = CPXcallbackrejectcandidate(
		cb.callback_data,
		Cint(1),
		Cint(length(coefficients)),
		Ref(rhs),
		Ref{Cchar}(sense),
		Ref{Cint}(0),
		indices,
		coefficients,
	)
end

"""
user cut callback
"""
function mysubmit(
	model::CPLEX.Optimizer,
	cb::MOI.UserCut{CPLEX.CallbackContext},
	f::MOI.ScalarAffineFunction{Float64},
	s::Union{
		MOI.LessThan{Float64},
		MOI.GreaterThan{Float64},
		MOI.EqualTo{Float64},
	},
)
	if model.callback_state == CPLEX._CB_LAZY
		throw(MOI.InvalidCallbackUsage(MOI.LazyConstraintCallback(), cb))
	elseif model.callback_state == CPLEX._CB_HEURISTIC
		throw(MOI.InvalidCallbackUsage(MOI.HeuristicCallback(), cb))
	elseif !iszero(f.constant)
		throw(
			MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(
				f.constant,
			),
		)
	end
	rmatind, rmatval = CPLEX._indices_and_coefficients(model, f)
	sense, rhs = CPLEX._sense_and_rhs(s)
	ret = CPXcallbackaddusercuts(
		cb.callback_data,
		Cint(1),
		Cint(length(rmatval)),
		Ref(rhs),
		Ref(sense),
		Ref{Cint}(0),
		rmatind,
		rmatval,
		Ref{Cint}(CPX_USECUT_FILTER),
		Ref{Cint}(1),
	)
	CPLEX._check_ret(model, ret)
end

"""
transform cutexpr to acceptable form
"""
function TransformCut(model, cutExpr, rhs, nterms)
	mymodel = backend(model)
	terms = Vector{MOI.ScalarAffineTerm{Float64}}(undef, nterms)
	i = 0
	for (coef, v) in linear_terms(cutExpr)
		i += 1
		varname = name(v)
		ind = MOI.get(mymodel, MOI.VariableIndex, varname)
		term = MOI.ScalarAffineTerm{Float64}(coef, ind)
		terms[i] = term
	end
	mycut = MOI.ScalarAffineFunction{Float64}(terms, 0.0)
	return mycut, MOI.GreaterThan(rhs)
end

function LazyAndUserCut(cb_data, model, theta, y, isLazy, V, clients, cost, CutClass)
	theta_vals = callback_value.(cb_data, theta)
	y_vals = callback_value.(cb_data, y)
	facilities = length(y_vals)
	for i in 1:clients
		isAdd, maxk = OptCons(V[i, :], facilities, cost[i, :], y_vals, theta_vals[i], CutClass)
		if isAdd
			mycut = theta[i] + sum((cost[i, V[i, maxk]] - cost[i, V[i, j]]) * y[V[i, j]] for j in 1:maxk-1)
			# add_to_expression!(mycut, sum( (cost[i, V[i, maxk]] - cost[i, V[i, j]]) * y[V[i, j]] for j in 1:maxk-1 ) )
			cut, rhs = TransformCut(model, mycut, cost[i, V[i, maxk]], maxk)
			cplex = backend(model)
			Cons = isLazy == 1 ? MOI.LazyConstraint : MOI.UserCut
			mysubmit(cplex, Cons(cb_data), cut, rhs)
			# cut = @build_constraint(theta[i] + sum( (cost[i, V[i, maxk]] - cost[i, V[i, j]]) * y[V[i, j]] for j in 1:maxk-1 ) >=
			#                         cost[i, V[i, maxk]])
			# @info "Adding cut: $(cut)"
			# Cons = isLazy == 1 ? MOI.LazyConstraint : MOI.UserCut
			# MOI.submit(model, Cons(cb_data), cut)
		end
	end
end

function MyMOIsubmit(model::Model, cb::MOI.UserCut, con::ScalarConstraint)
	return mysubmit(backend(model), cb, moi_function(con.func), con.set)
end

#function MyMOIsubmit(
#    model::Model,
#    cb::MOI.HeuristicSolution,
#    variables::Vector{VariableRef},
#    values::Vector{<:Real},
#)
#    return my_heur_submit(
#        backend(model),
#        cb,
#        index.(variables),
#        convert(Vector{Float64}, values),
#    )
#end
#function my_heur_submit(
#    model::Optimizer,
#    cb::CPXMOI.HeuristicSolution{CallbackContext},
#    variables::Vector{MOI.VariableIndex},
#    values::MOI.Vector{Float64},
#)
#    if model.callback_state == _CB_LAZY
#        throw(MOI.InvalidCallbackUsage(MOI.LazyConstraintCallback(), cb))
#    elseif model.callback_state == _CB_USER_CUT
#        throw(MOI.InvalidCallbackUsage(MOI.UserCutCallback(), cb))
#    end
#    ret = CPXcallbackpostheursoln(
#        cb.callback_data,
#        Cint(length(variables)),
#        Cint[_info(model, var).column - 1 for var in variables],
#        values,
#        NaN,
##        CPXCALLBACKSOLUTION_SOLVE,
#        CPXCALLBACKSOLUTION_NOCHECK,
#    )
#    _check_ret(model, ret)
#    return MOI.HEURISTIC_SOLUTION_UNKNOWN
#end
