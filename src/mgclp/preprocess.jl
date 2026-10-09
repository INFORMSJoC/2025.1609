include("./preprocess/greedy.jl")
include("./preprocess/utility.jl")

function Preprocess(param, dictF, F, theta, nSite, nClient, K, UBy, w, fn_data)

	time_str, time_pre, UB3 = 0.0, 0.0, nothing
	if param._bool["ubstr"] == true
		param_submgclp = Param(param)
		param_submgclp._bool["pre"] = false
		param_submgclp._bool["is_silent"] = false
		param_submgclp._float["nodelimit"] = 2
		UB3, time_str = MGCLP_Main_Func(F, theta, K; param = param_submgclp, fn_data = fn_data, w = w, is_submgclp = true)
	end
	start = time()
	vec_sites_closed = get_sites_closed(nSite, nClient, F)
	vec_sites_UBone = get_sites_UBone(nSite, nClient, F, vec_sites_closed)
	UBy[vec_sites_closed] .= 0
	UBy[vec_sites_UBone] .= 1
	ConfinedSitesk, val_greedy_y = GetSitesConfinedTok(F, theta, K, UBy, w, vec_sites_UBone, vec_sites_closed; UB3 = UB3, mode = param._string["mode"])
	for i in collect(keys(ConfinedSitesk))
		UBy[i] = ConfinedSitesk[i]
	end
	# @info vec_sites_closed
	@printf("Number of Closed Sites: %d / %d \n", length(vec_sites_closed), K * length(vec_sites_closed))
	# @info vec_sites_UBone
	@printf("Number of Confined Sites-1: %d / %d \n", length(vec_sites_UBone), (K - 1) * length(vec_sites_UBone))
	# @info ConfinedSitesk
	@printf("Number of Confined Sites-k: %d / %d \n", length(ConfinedSitesk), K * length(ConfinedSitesk) - sum(values(ConfinedSitesk)))

	time_pre = time() - start
	@printf("Preprocess Time: %.2f + %.2f sec\n\n", time_pre, time_str)

	for j in 1:nClient
		dictF[j][-1] = setdiff(dictF[j][-1], vec_sites_closed)
	end

	return UBy, dictF, val_greedy_y
end
