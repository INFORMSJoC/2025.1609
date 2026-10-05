mutable struct Coef
    indx_const::Vector{Int}
    x_const::Float64
    x::SparseVector{Float64,Int64}
    y::SparseVector{Float64,Int64}
    rhs::Float64
    cont::Float64
    type::String

    function Coef(nClient::Int, nSite::Int)
        new([], 0.0, spzeros(nClient), spzeros(nSite), 0.0, 1.0, "normal")
    end
end

function PrintCoef2(coef::Coef; str="", is_neg=false)

    if str != ""
        @printf("%s: ", str)
    end

    indx = findnz(coef.x)[1]
    indy = findnz(coef.y)[1]

    if is_neg == false
        @printf("%.4f etaP <= %.4f ", coef.cont, coef.rhs)
        for i in indy
            @printf(" + %.4f y[%d]", coef.y[i], i)
        end
        for i in indx
            @printf(" + %.4f x[%d]", coef.x[i], i)
        end

        if !isempty(coef.indx_const)
            @printf("+ %.4f (", coef.x_const)
            for xi in eachindex(coef.indx_const)
                @printf("x[%d]", coef.indx_const[xi])
                if xi < length(coef.indx_const)
                    @printf("+")
                else
                    @printf(")")
                end
            end
        end
        @printf("\n")
    else
        for i in indy
            @printf("%.4f y[%d] + ", coef.y[i], i)
        end
        for i in indx
            @printf("%.4f x[%d] + ", coef.x[i], i)
        end

        if !isempty(coef.indx_const)
            @printf("%.4f (", coef.x_const)
            for xi in eachindex(coef.indx_const)
                @printf("x[%d]", coef.indx_const[xi])
                if xi < length(coef.indx_const)
                    @printf("+")
                else
                    @printf(")")
                end
            end
        else
            @printf("0")
        end

        @printf(" <= %.4f + %.4f xi \n", coef.rhs, coef.cont)
    end

end
function calculate_violation(coef::Coef, val_x, val_y, val_etaj; is_Euclid_norm=false, is_num_nonzero=false)
    val_cut = coef.rhs
    Euclid_norm = 1
    num_nonzero = 0
    if !isempty(coef.indx_const)
        val_cut += coef.x_const * sum(val_x[coef.indx_const])
    end
    val_cut += val_x' * coef.x
    if !isnothing(val_y)
        val_cut += val_y' * coef.y
    end

    violation = val_etaj * coef.cont - val_cut
    # @info "vio: $(violation)"
    if is_Euclid_norm
        Euclid_norm = coef.x_const^2 * length(coef.indx_const)
        Euclid_norm += coef.x' * coef.x
        Euclid_norm += coef.y' * coef.y
        Euclid_norm += coef.cont^2 # for the coefficient of the only continuous variable
        violation = violation / Euclid_norm
    end

    if is_num_nonzero
        if !iszero(coef.x_const)
            num_nonzero += length(coef.indx_const)
        end
        num_nonzero += length(findnz(coef.x)[1]) + length(findnz(coef.y)[1])
    end
    return violation, Euclid_norm, num_nonzero
end


function compute_coef_cutM(nClient, nSite, critical_k, indIs_j, prob_j, val_x)

    prob_critical_k = critical_k >= 1 ? prob_j[indIs_j[critical_k]] : 0

    coef_cutM = Coef(nClient, nSite)
    coef_cutM.rhs = prob_critical_k
    val_rhs = prob_critical_k
    if critical_k == 0
        coef_cutM.x .= prob_j
    else
        ind = indIs_j[1:critical_k]
        coef_cutM.x[ind] .= prob_j[ind] .- prob_critical_k
    end
    val_rhs += coef_cutM.x' * val_x
    return coef_cutM, val_rhs
end

function get_set_C1(num_nnz, prob_nnz, val_x_nnz, delta_const; isprint=false, bC1_compare=-Inf, wrongly=false)
    set_C1, bC1 = [], 1.0
    gain = zeros(num_nnz)
    if isprint
        @info "prob_nnz: $(prob_nnz), delta_const: $(delta_const)"
        @info "val_x_nnz: $(val_x_nnz)"
    end
    for i in 1:num_nnz
        gain[i] = prob_nnz[i] * (delta_const - (1 - prob_nnz[i]) * val_x_nnz[i])
    end
    val_min, ind_min = findmin(gain)
    ind_left = [i for i in 1:num_nnz]
    if isprint
        @info "gain_start: $(gain)"
    end
    while val_min * bC1 < -EPS && bC1 > bC1_compare + EPS && bC1 > 1e-4
        append!(set_C1, ind_min)
        gain[ind_min] = 1.0
        temp_val = prob_nnz[ind_min] * val_x_nnz[ind_min]
        bC1 = bC1 * (1 - prob_nnz[ind_min])
        ind_left = [i for i in ind_left if bC1 * gain[i] < -EPS]
        for i in ind_left
            gain[i] += prob_nnz[i] * temp_val
        end
        val_min, ind_min = findmin(gain)
        if isprint
            @info "gain: $(gain)"
            @info "val_min=$(gain[ind_min]), ind_min=$(ind_min), bC1=$(bC1)"
        end
    end
    if isprint
        @info "pseudo_set_C1: $(set_C1)"
    end
    return set_C1, bC1
end


function get_set_C1_by_x(num_nnz, prob_nnz, val_x_nnz, val_y_nnz, delta_const, bC1_const; isprint=false, str=false)
    if isprint
        @info "prob_nnz: $(prob_nnz), delta_const: $(delta_const)"
        @info "val_x_nnz: $(val_x_nnz)"
    end

    set_C1, bC1 = [], 1.0
    ind_x_rev = sortperm(val_y_nnz .- val_x_nnz, rev=true)
    # ind_x_rev = sortperm(val_x_nnz, rev=true)
    delta_C1 = delta_const
    for sorted_i in 1:num_nnz
        i = ind_x_rev[sorted_i]
        if str == false
            delta_new = delta_C1 - (1 - prob_nnz[i]) * val_x_nnz[i]
        else
            delta_new = delta_C1 + prob_nnz[i] * (1 - prob_nnz[i]) * (val_y_nnz[i] - val_x_nnz[i]) + prob_nnz[i] * val_x_nnz[i] - prob_nnz[i] * (val_y_nnz[i] - val_x_nnz[i])
        end
        amount_decrease = bC1_const * bC1 * prob_nnz[i] * delta_new

        # if bC1_const * bC1 > EPS && amount_decrease < -1e-6
        if amount_decrease < -EPS * 1e-2
            append!(set_C1, i)
            delta_C1 = delta_new
            bC1 = bC1 * (1 - prob_nnz[i])
        else
            continue
        end
    end

    if isprint
        @info "pseudo_set_C1: $(set_C1)"
    end
    return set_C1, bC1
end

function get_set_C1_by_x_str(num_nnz, prob_nnz, val_x_nnz, val_y_nnz, delta_const; isprint=false)
    if isprint
        @info "prob_nnz: $(prob_nnz), delta_const: $(delta_const)"
        @info "val_x_nnz: $(val_x_nnz)"
    end

    set_C1, bC1 = [], 1.0
    ind_x_rev = sortperm(val_y_nnz .- val_x_nnz, rev=true)
    delta_C1 = delta_const
    for sorted_i in 1:num_nnz
        i = ind_x_rev[sorted_i]
        delta_new = delta_C1 + prob_nnz[i] * (1 - prob_nnz[i]) * (val_y_nnz[i] - val_x_nnz[i]) + prob_nnz[i] * val_x_nnz[i] - prob_nnz[i] * (val_y_nnz[i] - val_x_nnz[i])
        amount_decrease = bC1 * prob_nnz[i] * delta_new
        if amount_decrease < -EPS
            append!(set_C1, i)
            delta_C1 = delta_new
            bC1 = bC1 * (1 - prob_nnz[i])
        else
            continue
        end
    end

    if isprint
        @info "pseudo_set_C1: $(set_C1)"
    end
    return set_C1, bC1
end


function compute_coef_cutF_wrong(nClient, nSite, val_x, val_y, indy, indx_const, prob_j; atol=0.5, isprint=false)
    coef_cutF = nothing
    sum_val_x = sum(val_x[indx_const])
    if sum_val_x > 1 - EPS
    else
        # set_C1 = [i for i in indy if 1 - val_x[i] < EPS]
        set_C1 = []
        ind_nonzero = [i for i in indy if val_x[i] > EPS]
        setdiff!(ind_nonzero, set_C1)

        if !isempty(ind_nonzero)
            Delta_C = prob_j' * val_y
            if !isempty(set_C1)
                Delta_C += -sum(prob_j[i] * val_x[i] for i in set_C1)
            end
            gain = zeros(length(ind_nonzero))
            for ind in eachindex(ind_nonzero)
                i = ind_nonzero[ind]
                gain[ind] = prob_j[i] * (-Delta_C + 1 - val_x[i] * (1 - prob_j[i]))
            end
            Ind = sortperm(gain)
            # @info gain
            if isprint
                @info "Delta_C = $(Delta_C)"
                @info "gain = $(gain)"
            end
            while gain[Ind[1]] < -EPS
                i = ind_nonzero[Ind[1]]
                append!(set_C1, i)

                # update data

                Delta_C += -prob_j[i] * val_x[i]

                gain[Ind[1]] = 1
                for indj in 2:length(Ind)
                    j = Ind[indj]
                    if gain[Ind[j]] > EPS
                        break
                    end
                    gain[Ind[j]] = prob_j[j] * (-Delta_C + 1 - val_x[j] * (1 - prob_j[j]))
                end

                if isprint
                    @info "Delta_C = $(Delta_C)"
                    @info "gain = $(gain)"
                end
                Ind = sortperm(gain)
            end
        end

        coef_cutF = Coef(nClient, nSite)
        coef_cutF.indx_const = indx_const
        bC1 = 1

        # set_C1 = [i for i in indy if 1 - val_x[i] < atol]

        for i in set_C1
            bC1 = bC1 * (1 - prob_j[i])
        end

        for i in indy
            coef_cutF.y[i] = bC1 * prob_j[i]
        end

        for i in set_C1
            coef_cutF.x[i] = -coef_cutF.y[i]
        end

        coef_cutF.rhs = 1 - bC1
        coef_cutF.x_const = bC1
    end
    return coef_cutF

end

function compute_coef_cutF(nClient, nSite, val_x, val_y, indy, indx_const, prob_j; isprint=false, sepa=true)

    sum_val_x = sum(val_x[indx_const])
    if sum_val_x > 1 - EPS
        return nothing
    else
        set_C1, bC1, delta_const = [], 1.0, 1 - prob_j[indy]' * val_y[indy] - sum_val_x
        set_C1 = [i for i in indy if 1 - val_x[i] < EPS]
        for i in set_C1
            bC1 = bC1 * (1 - prob_j[i])
        end
        delta_const += prob_j[set_C1]' * val_x[set_C1]
        ind_nonzero = [i for i in setdiff(indy, set_C1) if val_x[i] > EPS]
        num_nnz = length(ind_nonzero)

        if sepa == true && num_nnz > 0
            if isprint
                @info "before: $(set_C1)"
            end
            pseudo_set_C1, bC1_part2 = get_set_C1_by_x(num_nnz, prob_j[ind_nonzero], val_x[ind_nonzero], val_y[ind_nonzero], delta_const; isprint=false)
            # pseudo_set_C1, bC1_part2 = get_set_C1(num_nnz, prob_j[ind_nonzero], val_x[ind_nonzero], delta_const; isprint=false)
            set_C1 = union(set_C1, ind_nonzero[pseudo_set_C1])
            bC1 = bC1 * bC1_part2
            if isprint
                @info "after: $(set_C1)"
                @info "val_x(set_C1): $(val_x[set_C1])"
                @info "val_x(ind_nnz): $(val_x[ind_nonzero])"
            end
        else
            set_C1, bC1 = [], 1.0
            set_C1 = [i for i in indy if 1 - val_x[i] < EPS + 0.5]
            for i in set_C1
                bC1 = bC1 * (1 - prob_j[i])
            end
        end
        coef_cutF = Coef(nClient, nSite)
        coef_cutF.indx_const = indx_const
        for i in indy
            coef_cutF.y[i] = bC1 * prob_j[i]
        end

        for i in set_C1
            coef_cutF.x[i] = -coef_cutF.y[i]
        end

        coef_cutF.rhs = 1 - bC1
        coef_cutF.x_const = bC1
        return coef_cutF
    end
end


# function compute_coef_cutF3(nClient, nSite, val_x, val_y, indy, indx_const, prob, j, num_node; isprint=false, sepa=true, str=false)

#    sum_val_x = sum(val_x[indx_const])
#    if sum_val_x > 1 + EPS
#       return nothing
#    else
#       set_C1, bC1, delta_const = Dict{Int,Int}(), 1.0, 0.0
#       val_y_rounded = round.(val_y)
#       for i in indy
#          if val_y_rounded[i] > EPS
#             # set_C1[i] = val_y_rounded[i]
#             set_C1[i] = 1
#             bC1 = bC1 * (1 - prob[i, j])^val_y_rounded[i]
#          end
#       end

#       coef_cutF = Coef(nClient, nSite)
#       coef_cutF.indx_const = indx_const

#       for i in indy
#          if i in keys(set_C1)
#             coef_cutF.y[i] = bC1 * prob[i, j]
#             coef_cutF.x[i] = -coef_cutF.y[i] * set_C1[i]
#          else
#             ki = max(1, floor(val_y[i]))
#             coef_cutF.y[i] = bC1 * prob[i, j] * (1 - prob[i, j])^ki
#             coef_cutF.x[i] = -coef_cutF.y[i] * ki + bC1 * (1 - (1 - prob[i, j])^ki)
#          end
#       end

#       coef_cutF.rhs = 1 - bC1
#       coef_cutF.x_const = bC1
#       return coef_cutF
#    end
# end


function compute_coef_cutP(nClient, nSite, indy, indx_const, LnFbar, PhiP, val_eta, val_x, val_y, val_y_round, j; str=false, flag=true)

    if str == false
        if sum(val_y[indx_const]) > val_eta - EPS
            return nothing
        else
            coef_cutP = Coef(nClient, nSite)
            coef_cutP.y[indy] = PhiP[j] .* [-LnFbar[j][i] for i in indy]
            coef_cutP.y[indx_const] .= 1
            coef_cutP.rhs = isempty(indy) ? 1 - PhiP[j] : 1 - PhiP[j] - sum(coef_cutP.y[i] * val_y_round[i] for i in indy)
            return coef_cutP
        end
    end

    if str == true
        if sum(val_x[indx_const]) > val_eta - EPS
            return nothing
        else
            # @info "flag: $flag"
            coef_cutP = Coef(nClient, nSite)
            coef_cutP.y[indy] = PhiP[j] .* [-LnFbar[j][i] for i in indy]
            coef_cutP.rhs = isempty(indy) ? 1 - PhiP[j] : 1 - PhiP[j] - sum(coef_cutP.y[i] * val_y_round[i] for i in indy)
            # @assert(coef_cutP.rhs > -EPS)
            val_coef_str = 1 - coef_cutP.rhs
            # flag = true
            if flag
                mask = coef_cutP.y[indy] .> val_coef_str + EPS
                # @info indy[mask]
                coef_cutP.x[indy[mask]] .= val_coef_str
                coef_cutP.y[indy[mask]] .= 0
                coef_cutP.x[indx_const] .= val_coef_str
            else
                coef_cutP.y[indy] = min.(coef_cutP.y[indy], val_coef_str)
                coef_cutP.y[indx_const] .= val_coef_str
            end
            # PrintCoef2(coef_cutP)
            return coef_cutP
        end
    end
    # else
    # 	coef_cutP.rhs = 1 - PhiP[j] - coef_cutP.y' * val_y_round
    # end
    # if abs(coef_cutP.y[indy]' * val_y_round[indy] - coef_cutP.y' * val_y_round) > EPS
    # 	@assert(false)
    # end

    # if str == true
    #    coef_cutP.x_const = 1 - coef_cutP.rhs
    #    indy_big_coef = [i for i in indy if coef_cutP.y[i] + EPS > coef_cutP.x_const]
    #    coef_cutP.indx_const = union(indy_big_coef, indx_const)
    #    coef_cutP.y[coef_cutP.indx_const] .= 0
    # end


    # if str == true
    # 	# tmp_ind = [i for i in indy if 2 * coef_cutP.y[i] > 1 - coef_cutP.rhs + EPS]
    # 	rhs = coef_cutP.rhs
    # 	for i in indy
    # 		coef_y = coef_cutP.y[i]
    # 		if coef_y > 1 - rhs + EPS
    # 			coef_cutP.x[i] = coef_y
    # 			coef_cutP.y[i] = 0
    # 		elseif 2 * coef_y > 1 - rhs + EPS
    # 			coef_cutP.x[i] = 2 * coef_cutP.y[i] + rhs - 1
    # 			coef_cutP.y[i] = 1 - rhs - coef_y
    # 		end
    # 	end
    # end
end

function compute_coef_cutP_local(nClient, nSite, PhiP_lb_j, Fj, val_x, lb_y, indx_const, indy)
    coef_cutLocal = nothing
    sum_lb_y = sum(lb_y[indx_const])
    sum_val_x = sum(val_x[indx_const])
    # if sum_lb_y > 1 - EPS
    #    coef_cutLocal = Coef(nClient, nSite)
    #    coef_cutLocal.rhs = -1
    #    coef_cutLocal.cont = -1
    if sum_val_x > 1 - EPS
    else
        coef_cutLocal = Coef(nClient, nSite)
        coef_cutLocal.y[indy] .= PhiP_lb_j * Fj[indy]
        coef_cutLocal.y[indx_const] .= PhiP_lb_j
        # coef_cutLocal.x_const = PhiP_lb_j
        # coef_cutLocal.indx_const = indx_const

        coef_cutLocal.rhs = 1 - PhiP_lb_j - coef_cutLocal.y' * lb_y
    end
    return coef_cutLocal
end
function f_and_nabla_f(val_y, indy, p)
    prod_term = 1
    for i in indy
        prod_term = prod_term * (1 - p[i])^val_y[i]
    end
    val_f = 1 - prod_term
    val_nabla_f = zeros(length(val_y))
    for i in indy
        val_nabla_f[i] = -prod_term * log(1 - p[i])
    end
    return val_f, val_nabla_f
end

function compute_coef_cutP_perspective(nClient, nSite, indy, indx_const, val_y, F, j; str=false)

    sum_val_y = sum(val_y[indx_const])
    if sum_val_y > 1 - EPS
        return nothing
    else
        zbar = sum_val_y
        fbar, nabla_fbar = f_and_nabla_f(val_y ./ (1 - zbar), indy, F[:, j])
        coef_cutP = Coef(nClient, nSite)
        coef_cutP.y[indy] .= nabla_fbar[indy]
        coef_cutP.x_const = 1 - fbar + nabla_fbar' * val_y / (1 - zbar)
        coef_cutP.indx_const = indx_const[:]
        coef_cutP.rhs = 1 - coef_cutP.x_const

        if str == true
            indx_const_new = [i for i in indy if coef_cutP.y[i] > EPS + coef_cutP.x_const]
            # @info "coef_x_const", coef_cutP.x_const, indx_const_new
            # @info "coef_y", coef_cutP.y[indy]
            append!(coef_cutP.indx_const, indx_const_new)
            coef_cutP.y[indx_const_new] .= 0
        end
        return coef_cutP
    end
end
function compute_coef_cutC(nClient, nSite, indy, indx_const, LnFbarj, PhiPj, val_x, val_gamma; str=false)

    coef_gamma, coef_x_const, coef_rhs = nothing, nothing, nothing
    sum_val_x = sum(val_x[indx_const])
    if sum_val_x > 1 - EPS
    else
        coef_gamma = exp(-val_gamma)
        coef_rhs = 1 - exp(-val_gamma) - coef_gamma * val_gamma
        coef_x_const = 1 - coef_rhs
    end

    return coef_gamma, coef_x_const, coef_rhs
end

function compute_coef_MIR(nClient, nSite, CoefVecAggr_j, val_x, val_y, val_etaPj, indx_lb, indx_ub, indy_lb, indy; isprint=false)

    coef_MIR, Euclid_norm_MIR = nothing, 1

    if length(CoefVecAggr_j) > 2
        VioVecAggr_j = zeros(length(CoefVecAggr_j))

        # @info "aha"
        if isprint
            # @info "CoefVecAggr_j", CoefVecAggr_j
            @info "CoefVecAggr_j"
            for ind_coef in eachindex(CoefVecAggr_j)
                PrintCoef2(CoefVecAggr_j[ind_coef])
            end
        end
        # Step 1. find the most violated cut of CutVectorAggr; the Euclidean distance is not used here because the two cuts are subtracted below
        for ind_coef in eachindex(CoefVecAggr_j)
            coef = CoefVecAggr_j[ind_coef]
            vio, _, _ = calculate_violation(coef, val_x, val_y, val_etaPj)    # is_Euclid_norm ? 
            VioVecAggr_j[ind_coef] = vio
        end

        _, ind_coef_pre1 = findmax(VioVecAggr_j) # what if vio_pre1 < EPS? the MIR step may still produce a violated cut
        coef_pre1 = CoefVecAggr_j[ind_coef_pre1]

        if isprint
            # @info "coef_pre1", coef_pre1
            PrintCoef2(coef_pre1; str="coef_pre1")
        end
        # Step 2. aggregate it with the other cuts of CutVectorAggr and apply MIR; the largest violation in Euclidean distance is taken here
        max_aggr_vio = -Inf
        VioDoubleVec = Vector{Vector{Float64}}(undef, length(CoefVecAggr_j))
        # @info "forloop"

        for ind_coef_pre2 in eachindex(CoefVecAggr_j)
            coef_pre2 = CoefVecAggr_j[ind_coef_pre2]
            VioDoubleVec[ind_coef_pre2] = []
            if ind_coef_pre2 != ind_coef_pre1
                if isprint
                    # @info "coef_pre2", coef_pre2
                    PrintCoef2(coef_pre2; str="coef_pre2")
                end
                coef_neg, coef_cont_var = calc_MIR_aggregation(nClient, nSite, coef_pre1, coef_pre2; isprint=isprint)
                if isprint
                    PrintCoef2(coef_neg; str="coef_neg", is_neg=true)
                    # @info "coef_neg", coef_neg
                end
                # @info "inner loop $(ind_coef_pre2)"
                if !isnothing(coef_neg)
                    arr_delta = select_arr_delta(coef_neg, "max")
                    for delta in eachindex(arr_delta)
                        # aggregation 
                        # calculate the coefficients after MIR
                        if isprint
                            @info "delta = $(delta)"
                        end
                        # @info "indx_lb", indx_lb
                        coef_aggr_MIR = calc_MIR_coef(coef_neg, coef_cont_var, delta, indx_lb, indx_ub, indy, indy_lb; isprint=isprint)
                        if !isnothing(coef_aggr_MIR)
                            vio_aggr_MIR, Euclid_norm_aggr_MIR, _ = calculate_violation(coef_aggr_MIR, val_x, val_y, val_etaPj; is_Euclid_norm=true)
                            if vio_aggr_MIR > max_aggr_vio
                                max_aggr_vio, coef_MIR, Euclid_norm_MIR = vio_aggr_MIR, coef_aggr_MIR, Euclid_norm_aggr_MIR
                            end
                        end
                    end
                end
            end
        end
    end

    return coef_MIR
end

function select_arr_delta(coef::Coef, type="max")
    arr_delta = []
    if type == "max"
        temp_arr = union(coef.x, coef.y, coef.x_const, coef.cont)
        push!(arr_delta, maximum(temp_arr))
    end
    return arr_delta
end

function calc_MIR_aggregation(nClient, nSite, coef1::Coef, coef2::Coef; isprint=false)

    if occursin("bound", coef1.type) && occursin("bound", coef2.type)
        coef_neg = nothing
    else
        coef_neg = Coef(nClient, nSite)
        if occursin("bound", coef2.type)
            (coef1, coef2) = (coef2, coef1)
        end

        if coef1.type == "lower_bound"
            coef_neg.cont = 0.0
        elseif coef1.type == "upper_bound" || coef1.type == "normal"
            coef_neg.cont = 1.0
        end

        # if isprint
        #    @info "coef1.indx_const", coef1.indx_const
        #    @info "coef2.indx_const", coef2.indx_const
        # end
        coef_neg.x = coef1.x - coef2.x
        coef_neg.y = coef1.y - coef2.y
        coef_neg.rhs = coef2.rhs - coef1.rhs


        if !isempty(coef1.indx_const)
            coef_neg.x[coef1.indx_const] .+= coef1.x_const
        end

        if !isempty(coef2.indx_const)
            coef_neg.x[coef2.indx_const] .+= -coef2.x_const
        end
    end
    return coef_neg, coef1

end

function calc_MIR_coef(coef_neg::Coef, coef_cont_var::Coef, delta, indx_lb, indx_ub, indy, indy_lb; isprint=false)
    function G(d, f)
        f_d = d - floor(d)
        return floor(d) + (max(0, f_d - f) / (1 - f))
    end

    ind_coef_neg = union(findnz(coef_neg.x)[1], findnz(coef_neg.y)[1], coef_neg.indx_const)
    each_indy_lb = intersect(indy, indy_lb)
    # update the coefficients after substituting y_i by x_i + t_i
    if !isempty(each_indy_lb)
        for i in each_indy_lb
            coef_neg.x[i] += coef_neg.y[i]
        end
    end
    newrhs = coef_neg.rhs
    # newrhs += - sum(coef_neg.y[i] for i in intersect(indx_ub, indy_lb))

    indx, val_indx = findnz(coef_neg.x)
    each_indx_ub = intersect(indx, indx_ub)
    each_indx_lb = intersect(indx, indx_lb)

    if !isempty(indx_ub)
        newrhs += -sum(coef_neg.x[i] for i in indx_ub)
    end
    newrhs = newrhs / delta

    f = newrhs - floor(newrhs)
    if abs(f) < EPS
        return nothing
    end
    if isprint
        PrintCoef2(coef_neg; str="new coef_neg", is_neg=true)
        @info "each_indy_lb", each_indy_lb
        @info "indx", indx, "each_indx_lb", each_indx_lb, "each_indx_ub", each_indx_ub
        @info "f=$(f), newrhs = $(newrhs)"
    end
    coef_MIR = Coef(nClient, nSite)
    coef_MIR.type = "MIR"

    if !isempty(indy)
        for i in indy
            coef_MIR.y[i] += G(coef_neg.y[i] / delta, f)
        end
    end

    sum_coef_x = 0
    if !isempty(each_indx_ub)
        for i in each_indx_ub
            coef_MIR.x[i] += -G(-coef_neg.x[i] / delta, f)
            sum_coef_x += coef_MIR.x[i]
        end
    end

    if !isempty(each_indx_lb)
        for i in each_indx_lb
            coef_MIR.x[i] += G(coef_neg.x[i] / delta, f)
        end
    end

    if !isempty(each_indy_lb)
        for i in each_indy_lb
            coef_MIR.x[i] += -coef_MIR.y[i]
        end
    end

    coef_MIR.cont = coef_neg.cont / (delta * (1 - f))
    coef_MIR.rhs = floor(newrhs) + sum_coef_x
    # if !isempty(indx_ub)
    #    coef_MIR.rhs += + sum(coef_MIR.x[i] for i in indx_ub)
    # end


    # normalization
    coef_MIR.x = -coef_MIR.x / coef_MIR.cont
    coef_MIR.y = -coef_MIR.y / coef_MIR.cont
    coef_MIR.rhs = coef_MIR.rhs / coef_MIR.cont
    coef_MIR.cont = 1

    if isprint
        # @info "coef_MIR", coef_MIR
        PrintCoef2(coef_MIR; str="coef_MIR", is_neg=true)
    end
    if coef_cont_var.type == "lower_bound"
    else
        coef_MIR.rhs += coef_cont_var.rhs
        if coef_cont_var.type == "upper_bound"
        else
            coef_MIR.x += coef_cont_var.x
            coef_MIR.y += coef_cont_var.y
            if !isempty(coef_cont_var.indx_const)
                for i in coef_cont_var.indx_const
                    coef_MIR.x[i] += coef_cont_var.x_const
                end
            end
        end
    end

    # coef_MIR.x = -coef_MIR.x
    # coef_MIR.y = -coef_MIR.y

    if isprint
        # @info "coef_MIR_real", coef_MIR
        PrintCoef2(coef_MIR; str="coef_MIR_real")
    end
    return coef_MIR

end
