

function BuildModel(F, K, theta, w, indIs, model; mode = "", UBy, dictF, LnFbar, ImplyUBCut = false, is_relaxed = false, colocation::Bool = true)

	is_etaP_nothing = isapprox(theta, 1.0; atol = 1e-6)
	if !(mode == "Int" || mode == "Bin")
		error("mode must be \"Int\" or \"Bin\", got \"$(mode)\" (pass mode=Int or mode=Bin)")
	end
	nSite, nClient = size(F)
	x_var = nothing

	@variable(model, 0 <= etaM[j in 1:nClient] <= 1)
	is_etaP_nothing ? etaP = nothing : @variable(model, 0 <= etaP[j in 1:nClient] <= 1)

	obj_expr = theta * sum(w[j] * etaM[j] for j in 1:nClient)
	if !is_etaP_nothing
		obj_expr += (1 - theta) * sum(w[j] * etaP[j] for j in 1:nClient)
	end
	@objective(model, Max, obj_expr)

	# if mode == "Int"
	if contains(mode, "Int")
		is_relaxed ? @variable(model, 0 <= x[i in 1:nSite] <= 1) : @variable(model, x[i in 1:nSite], Bin)
		y = nothing
		if !is_etaP_nothing
			if colocation
				is_relaxed ? @variable(model, 0 <= y[i in 1:nSite] <= UBy[i]) : @variable(model, 0 <= y[i in 1:nSite] <= UBy[i], Int)
				if ImplyUBCut == false
					@constraint(model, [i = 1:nSite], y[i] <= UBy[i] * x[i])
				end
				@constraint(model, [i = 1:nSite], x[i] <= y[i])
				@constraint(model, sum(y[i] for i in 1:nSite) <= K)
			else
				# NoCoLoc: y = x (x[i] ∈ {0,1} serves as both location and count)
				# Downstream cut code works unchanged: LS→k_i=1, EOA→y_i replaced by x_i
				y = x
				model[:y] = y
				@constraint(model, sum(x[i] for i in 1:nSite) <= K)
			end
		else
			@constraint(model, sum(x[i] for i in 1:nSite) <= K)
		end
		# @info "colocation: $(colocation)"

	elseif mode == "Bin"
		if colocation
			is_relaxed ? @variable(model, 0 <= x[i in 1:nSite, k in 1:K] <= 1) : @variable(model, x[i in 1:nSite, k in 1:K], Bin)
			x_var = nothing
			@constraint(model, SYM[i = 1:nSite, k = 1:K-1], x[i, k+1] <= x[i, k])
			@constraint(model, CARD, sum(x) <= K)
		else
			active_x = [(i, 1) for i in 1:nSite]
			is_relaxed ? @variable(model, 0 <= x_active[active_x] <= 1) : @variable(model, x_active[active_x], Bin)
			x = Matrix{Any}(fill(0, nSite, K))
			x_var = Dict{Tuple{Int, Int}, Any}()
			for ind in active_x
				x[ind...] = x_active[ind]
				x_var[ind] = x_active[ind]
			end
			model[:x] = x
			@constraint(model, CARD, sum(values(x_var)) <= K)
		end
		y = nothing
		for i in 1:nSite
			for k in (UBy[i]+1):K
				if x[i, k] != 0
					@constraint(model, x[i, k] == 0)
				end
			end
		end
	end

	set_upper_bound.(etaM, [F[indIs[1, j], j] for j in 1:nClient])

	return model, MGCLP(x, y, etaM, etaP, x_var)
end
