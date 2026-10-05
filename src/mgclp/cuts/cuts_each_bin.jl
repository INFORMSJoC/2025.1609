
function BuildCuts_Bin(val, mgclp, phase::String, CutVector, nClient, nSite, dictF, indIs, F;
    cutM=false, cutP=false, is_Euclid_norm=false)
    function CalcViolation_CutP_Bin(PhiP_j, F_j, val_x, val_etaPj)
        violation = val_etaPj - (1 - PhiP_j + PhiP_j * sum(F_j[i] * val_x[i] for i in 1:nSite))
        return violation
    end
    cut_info = Dict(cutname => Stat_Cut([phase]) for cutname in ["max", "prod_bin"])

    CriticalK = GetCriticalK(val.x[:, 1], indIs)
    val_y_round = zeros(Int, nSite)
    for i in 1:nSite
        val_y_round[i] = round(Int, sum(round.(Int, val.x[i, :])))
    end
    PhiP = GetProduction(nSite, nClient, val_y_round, F)
    val_x_vio = zeros(nSite)
    var_x_vio = Vector{AffExpr}(undef, nSite)
    for i in 1:nSite
        if val_y_round[i] < K
            ind = val_y_round[i] + 1
            val_x_vio[i] = sum(val.x[i, ind:K])
            var_x_vio[i] = sum(mgclp.x[i, ind:K])
        else
            var_x_vio[i] = 0
        end
    end
    for j in 1:nClient
        if cutM == true
            start = time()
            cutname = "max"
            coef, _ = compute_coef_cutM(nClient, nSite, CriticalK[j], indIs[:, j], F[:, j], val.x[:, 1])
            if !isnothing(coef)
                vio, Euclid_norm, _ = calculate_violation(coef, val.x[:, 1], nothing, val.etaM[j]; is_Euclid_norm=is_Euclid_norm)
                if vio > EPS
                    mycut, _, num_nonzero_cutM = calculate_violation(coef, mgclp.x[:, 1], nothing, mgclp.etaM[j]; is_num_nonzero=true)
                    consM = @build_constraint(mycut / Euclid_norm <= 0)
                    push!(CutVector, consM)
                    cut_info[cutname].Num[phase] += 1
                    cut_info[cutname].AverNNZ[phase] += num_nonzero_cutM # not an average yet
                end
            end
            duration = time() - start
            cut_info[cutname].Time[phase] += duration
        end


        if cutP == true
            start = time()
            cutname = "prod_bin"
            if PhiP[j] > 1e-6 && 1 - PhiP[j] < val.etaP[j]
                violation = CalcViolation_CutP_Bin(PhiP[j], F[:, j], val_x_vio, val.etaP[j])
                if violation > EPS
                    mycut = CalcViolation_CutP_Bin(PhiP[j], F[:, j], var_x_vio, mgclp.etaP[j])
                    CutP = @build_constraint(mycut <= 0)
                    push!(CutVector, CutP)
                    cut_info[cutname].Num[phase] += 1
                    #cut_info[cutname].AverNNZ[phase] += num_nonzero_cutP # not an average yet
                end
            end
            duration = time() - start
            cut_info[cutname].Time[phase] += duration
        end
    end
    nCutM, nCutP = cut_info["max"].Num[phase], cut_info["prod_bin"].Num[phase]
    return cut_info, nCutM, nCutP
end
