"""
   Read_Pmed_Uncapacitied(fn)
Brief:
   1. read part of the cost from pmed data file (uncapacitied)
   2. get the whole cost matrix using Floyd Algortihm.
Param:
- fn::String               name of pmed data file 
Return 
- Cost::Matrix{Float64}    matrix to store the cost of pmed problem
"""
function Read_Pmed_Uncapacited(fn)
   #   println("Read Demand File: ! ", fn)
   #   @info "read data"
   data = readlines(fn)
   str = split(data[1], ' ', keepempty=false)

   # read the first line
   nVertex = parse(Int, str[1])
   nEdge = parse(Int, str[2])
   p = parse(Int, str[3])

   if length(str) >= 4 && uppercase(str[4]) == "COORD_PMED"
      return p, Read_Pmed_Coordinates(data, nVertex, nEdge)
   end

   Cost = Inf * ones(Float64, nVertex, nVertex)
   path_road = zeros(Int, nVertex, nVertex)

   for i in 1:nVertex
      Cost[i, i] = 0
   end

   # read the left and build a symmetic matrix
   for i in 2:nEdge+1
      str = split(data[i], ' ', keepempty=false)
      vertex1 = parse(Int, str[1])
      vertex2 = parse(Int, str[2])
      Cost[vertex1, vertex2] = parse(Int, str[3])
      Cost[vertex2, vertex1] = Cost[vertex1, vertex2]
   end

   # Floyed Algorithm
   for k in 1:nVertex, i in 1:nVertex, j in 1:nVertex
      if Cost[i, j] > Cost[i, k] + Cost[k, j]
         Cost[i, j] = Cost[i, k] + Cost[k, j]
         path_road[i, j] = k
      end
   end

   #   @info "Cost[284,6]=$(Cost[284,6])"
   return p, Cost
end

"""
   Read_Pmed_Coordinates(data, nSite, nClient)

Read a coordinate pmed instance. The first line is

   nSite nClient K COORD_PMED ...

followed by a `CUSTOMERS` block with `nClient` rows and a `LOCATIONS` block
with `nSite` rows. Each coordinate row has `id x y`. The returned matrix has
rows indexed by candidate locations and columns indexed by customers.
"""
function Read_Pmed_Coordinates(data, nSite, nClient)
   function read_coord_block(block_name, start_line, expected_count)
      if start_line > length(data) || uppercase(strip(data[start_line])) != block_name
         error("Expected $(block_name) block in coordinate pmed instance.")
      end
      coords = zeros(Float64, expected_count, 2)
      for row in 1:expected_count
         line_no = start_line + row
         if line_no > length(data)
            error("Missing coordinate row $(row) in $(block_name) block.")
         end
         fields = split(data[line_no], ' ', keepempty=false)
         if length(fields) < 3
            error("Invalid coordinate row $(line_no): $(data[line_no])")
         end
         idx = parse(Int, fields[1])
         if idx < 1 || idx > expected_count
            error("Coordinate index $(idx) out of range in $(block_name) block.")
         end
         coords[idx, 1] = parse(Float64, fields[2])
         coords[idx, 2] = parse(Float64, fields[3])
      end
      return coords, start_line + expected_count + 1
   end

   customers, next_line = read_coord_block("CUSTOMERS", 2, nClient)
   locations, _ = read_coord_block("LOCATIONS", next_line, nSite)

   Cost = zeros(Float64, nSite, nClient)
   for i in 1:nSite, j in 1:nClient
      dx = locations[i, 1] - customers[j, 1]
      dy = locations[i, 2] - customers[j, 2]
      Cost[i, j] = sqrt(dx * dx + dy * dy)
   end
   return Cost
end

"""
   ReadWeights(fn_weight)
Brief:
   1. read the weight from fn_weight
Param:
- fn::String               name of weight file 
Return 
- w::Matrix{Float64}    matrix to store the weight of pmed problem
"""


function ReadWeights(fn_weight)
   data = readlines(fn_weight)
   nClient = parse(Int, data[1])
   w = zeros(nClient)
   for i in 2:length()
      str = split(data[i], ' ', keepempty=false)
      j = parse(Int, str[1])
      w[j] = parse(Float64, str[2])
   end
   return w
end


const LOGIT_QUADRATIC_PROFILES = Dict(
   "logit_slow" => (-3.0, 1.0, 4.0),
   "logit_mid" => (-3.0, 6.0, 0.0),
   "logit_medium" => (-3.0, 6.0, 0.0),
   "logit_fast" => (-3.0, 10.0, -4.0),
)

function LogisticQuadraticCoverage(d, r, R, alpha, beta, gamma; EPS=1e-6)
   if d <= r
      return 1.0
   elseif d >= R
      return 0.0
   end

   x = (d - r) / (R - r)
   z = alpha + beta * x + gamma * x^2
   if z > 700
      return 0.0
   elseif z < -700
      return 1.0
   end
   return 1 / (1 + exp(z))
end

function GetLogitQuadraticProfile(prob_func)
   key = lowercase(prob_func)
   if !haskey(LOGIT_QUADRATIC_PROFILES, key)
      valid = join(sort(collect(keys(LOGIT_QUADRATIC_PROFILES))), ", ")
      error("Unknown logistic-quadratic probability profile: $(prob_func). Valid values: $(valid)")
   end
   return LOGIT_QUADRATIC_PROFILES[key]
end

"""
TransformIntoF(Cost, r, R)
Brief:
   1. transform the cost matrix into probability matrix F
Param:
- Cost::Matrix{Float64}            cost matrix
- r::Float64                        
- R::Float64                       
- prob_func::String                linear, facility_mixture, logit_slow, logit_mid, logit_fast
Return 
- F::Matrix{Float64}    the probability matrix 
- numC1::Int            the number of values which equal to 1 in the probability matrix
- numCP::Int            the number of values which range from 0 to 1 in the probability matrix
"""
function TransformIntoF(Cost, r=5, R=20; EPS=1e-6, prob_func="linear",
   mixture_low_share=0.8, mixture_low_min=0.001, mixture_low_max=0.01,
   mixture_high_min=0.9, mixture_high_max=0.99, mixture_seed=1)

   nVertex, nEdge = size(Cost)
   F = zeros(nVertex, nEdge)
   numC1, numCP = 0, 0
   prob_func_key = lowercase(prob_func)
   if prob_func_key in ["linear", ""]
      if abs(R - r) < EPS
         for i in 1:nVertex, j in 1:nEdge
            if Cost[i, j] < R
               F[i, j] = 1
               numC1 += 1
            end
         end
      else
         # transform the distance matrix into fij
         for i in 1:nVertex, j in 1:nEdge
            F[i, j] = min(1, max(0, (r - Cost[i, j]) / (R - r) + 1))
            if F[i, j] == 1
               numC1 += 1
            elseif 0 < F[i, j] < 1
               numCP += 1
            end
         end
      end
   elseif prob_func_key in ["facility_mixture", "facility_mix", "low_high"]
      if mixture_low_share < -EPS || mixture_low_share > 1 + EPS
         error("mixture_low_share must be between 0 and 1.")
      end
      if mixture_low_min < -EPS || mixture_low_max > 1 + EPS || mixture_low_min > mixture_low_max
         error("mixture low interval must satisfy 0 <= low_min <= low_max <= 1.")
      end
      if mixture_high_min < -EPS || mixture_high_max > 1 + EPS || mixture_high_min > mixture_high_max
         error("mixture high interval must satisfy 0 <= high_min <= high_max <= 1.")
      end

      low_share = min(1.0, max(0.0, mixture_low_share))
      rng = MersenneTwister(mixture_seed)
      facility_prob = zeros(nVertex)
      shuffled_sites = shuffle(rng, collect(1:nVertex))
      n_high = round(Int, nVertex * (1.0 - low_share))
      high_sites = Set(shuffled_sites[1:n_high])
      for i in 1:nVertex
         if i in high_sites
            facility_prob[i] = mixture_high_min + rand(rng) * (mixture_high_max - mixture_high_min)
         else
            facility_prob[i] = mixture_low_min + rand(rng) * (mixture_low_max - mixture_low_min)
         end
      end

      for i in 1:nVertex, j in 1:nEdge
         d = Cost[i, j]
         if d <= r
            F[i, j] = 1.0
            numC1 += 1
         elseif d < R
            F[i, j] = facility_prob[i]
            if isapprox(F[i, j], 1.0; atol=EPS)
               numC1 += 1
            elseif EPS < F[i, j] < 1 - EPS
               numCP += 1
            end
         else
            F[i, j] = 0.0
         end
      end
   else
      alpha, beta, gamma = GetLogitQuadraticProfile(prob_func_key)
      if R <= r + EPS
         error("Logistic-quadratic probability profiles require R > r.")
      end
      for i in 1:nVertex, j in 1:nEdge
         F[i, j] = LogisticQuadraticCoverage(Cost[i, j], r, R, alpha, beta, gamma; EPS=EPS)
         if isapprox(F[i, j], 1.0; atol=EPS)
            numC1 += 1
         elseif EPS < F[i, j] < 1 - EPS
            numCP += 1
         end
      end
   end
   return F, numC1, numCP
end


function getstartvalue(fn_data, F, indIs, mode="Int")
   start = time()

   nSite, nClient = size(F)

   data = readlines(fn_data)
   ind_Site = Set{Int64}()

   val_y = zeros(Int, nSite, 1)
   for i in 1:length(data)
      str = split(data[i], ',', keepempty=false)
      start_site = split(str[1], "(", keepempty=false)
      start_site = parse(Int, start_site[1])
      start_num = split(str[2], ")", keepempty=false)
      start_num = parse(Int, start_num[1])
      val_y[start_site] = start_num
      push!(ind_Site, start_site)
   end

   if mode == "Bin"
      val_x = zeros(Int, nSite, K)
      for i in ind_Site
         k = val_y[i]
         val_x[i, 1:k] .= 1
      end
   elseif mode == "Int"
      val_x = zeros(Int, nSite)
      for i in ind_Site
         val_x[i] = 1
      end
   end
   val_etaM_calc, val_etaP_calc = GetEtaFromScratch(val_x, val_y, F, indIs, nSite, nClient, mode)
   start_val = MGCLP(val_x, val_y, val_etaM_calc, val_etaP_calc)
   duration = time() - start
   return duration, start_val
end

function read_mgclp_solution(fn, fnsol, r, R, theta, nSite)
   temp = split(fn, '/', keepempty=false)
   # Extract the number from the string using the regular expression
   # Define the regular expression to match the number
   regex = r"pmed(\d+)\.txt"
   match_str = match(regex, temp[length(temp)])

   # Get the matched number as a string
   number_str = match_str.captures[1]

   # Convert the number string to an integer
   number = parse(Int, number_str)

   fnstr = "$(number)-$(round(Int,r))-$(round(Int,R))-$(theta)"

   dict_sol = Dict{Int,Int}()
   # data = readlines(fnsol)
   file = open(fnsol, "r")
   valy = zeros(Int, nSite)
   for line in eachline(file)
      data = split(line, ' ', keepempty=false)
      if data[1] == fnstr
         valstr = split(data[2], ':', keepempty=false)
         val = parse(Int, valstr[1])
         for i in 3:length(data)
            tempstr = split(data[i], ',', keepempty=false)
            ind = parse(Int, tempstr[1])
            dict_sol[ind] = val
         end
      end
   end
   return dict_sol
end
