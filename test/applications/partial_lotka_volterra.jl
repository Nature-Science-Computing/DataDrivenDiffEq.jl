using DataDrivenDiffEq
using ModelingToolkit
using LinearAlgebra
@info "Loading DiffEqSensitivity"
using DiffEqSensitivity
@info "Loading Optim"
using Optim
@info "Loading DiffEqFlux"
using DiffEqFlux
@info "Loading Flux"
using Flux
@info "Loading OrdinaryDiffEq"
using OrdinaryDiffEq
using Test
using JLD2
@info "Finished loading packages"

const losses = []

@info "Started Lotka Volterra UODE Testset"
@info "Generate data"

function lotka_volterra(du, u, p, t)
    α, β, γ, δ = p
    du[1] = α*u[1] - β*u[2]*u[1]
    du[2] = γ*u[1]*u[2]  - δ*u[2]
end

tspan = (0.0f0,3.0f0)
u0 = Float32[0.44249296,4.6280594]
p_ = Float32[1.3, 0.9, 0.8, 1.8]
prob = ODEProblem(lotka_volterra, u0,tspan, p_)
solution = solve(prob, Vern7(), abstol=1e-12, reltol=1e-12, saveat = 0.1)

# Ideal data
tsdata = Array(solution)
# Add noise to the data
noisy_data = tsdata + Float32(1e-5)*randn(eltype(tsdata), size(tsdata))

@info "Setup neural network and auxillary functions"
ann = FastChain(FastDense(2, 32, tanh),FastDense(32, 64, tanh),FastDense(64, 32, tanh), FastDense(32, 2))
p = initial_params(ann)

function dudt_(u, p,t)
    x, y = u
    z = ann(u,p)
    [p_[1]*x + z[1],
    -p_[4]*y + z[2]]
end

prob_nn = ODEProblem(dudt_,u0, tspan, p)
s = solve(prob_nn, Tsit5(), u0 = u0, p = p, saveat = solution.t)

function predict(θ)
    Array(solve(prob_nn, Vern7(), u0 = u0, p = θ, saveat = solution.t,
                         abstol=1e-6, reltol=1e-6))
end

# No regularisation right now
function loss(θ)
    pred = predict(θ)
    sum(abs2, noisy_data .- pred), pred # + 1e-5*sum(sum.(abs, params(ann)))
end

callback(θ,l,pred) = begin
    push!(losses, l)
    if length(losses)%10 == 0
        println("Loss after $(length(losses)) iterations $(losses[end])")
    end
    false
end

if !isfile(joinpath(dirname(@__FILE__), "partial_lotka_volterra.jld2"))
    @info "Initial loss $(loss(p)[1])"
    @info "Train neural network until converged"
    res1 = DiffEqFlux.sciml_train(loss, p, ADAM(0.01), cb=callback, maxiters = 100)
    @info "Finished initial training with loss $(losses[end])"
    res2 = DiffEqFlux.sciml_train(loss, res1.minimizer, BFGS(initial_stepnorm=0.01), cb=callback, maxiters = 10000)
    @info "Finished extended training with loss $(losses[end])"
    p_trained = res2.minimizer
    @save "$(joinpath(dirname(@__FILE__), "partial_lotka_volterra.jld2"))" p_trained

    # Check for the convergence of loss
    # Necessary for result
    @test losses[end] <= 1e-2
else
    @info "Loading pretrained parameters"
    @load "$(joinpath(dirname(@__FILE__), "partial_lotka_volterra.jld2"))" p_trained
end

# Plot the data and the approximation
NNsolution = predict(p_trained)

@test norm(NNsolution .- solution, 2) < 0.1

Y = ann(noisy_data, p_trained)
X = noisy_data
# Create a Basis
@variables u[1:2]
# Lots of polynomials
polys = Any[1]
for i ∈ 1:5
    push!(polys, u[1]^i)
    push!(polys, u[2]^i)
    for j ∈ i:5
        if i != j
            push!(polys, (u[1]^i)*(u[2]^j))
            push!(polys, u[2]^i*u[1]^i)
        end
    end
end

# And some other stuff
h = [cos.(u)...; sin.(u)...; polys...]
basis = Basis(h, u)

# Create an optimizer for the SINDy problem
opt = SR3()
# Create the thresholds which should be used in the search process
λ = exp10.(-10:0.05:-0.5)
# Target function to choose the results from; x = L0 of coefficients and L2-Error of the model
g(x) = x[1] < 1 ? Inf : norm(x, 2)
@info "Start SINDy regression with unknown threshold"
# Test on uode derivative data
Ψ = SINDy(X[:, 2:end], Y[:, 2:end], basis, λ, opt, g = g, maxiter = 10000, normalize = true, denoise = true) # Succeed
print_equations(Ψ)
p̂ = parameters(Ψ)
@info "Build initial guess system"
# The parameters are a bit off, so we reiterate another SINDy term to get closer to the ground truth
# Create function
unknown_sys = ODESystem(Ψ)
unknown_eq = ODEFunction(unknown_sys)
# Just the equations
b = Basis((u, p, t)->unknown_eq(u, ones(size(p̂)), t), u)
# Test on uode derivative data
@info "Refine the guess"
Ψ = SINDy(X[:, 2:end], Y[:, 2:end],b, SR3(0.1), maxiter = 1000) # Succeed
p̂ = parameters(Ψ)

@info "Checking equations"
found_basis = map(x->simplify(x.rhs), equations(Ψ.equations))
pps = parameters(Ψ.equations)

expected_eqs = Vector{Any}()
for _p in pps
    push!(expected_eqs, _p*u[1]*u[2])
end
@test all(isequal.(found_basis, expected_eqs))
@test isapprox(abs.(p̂), p_[2:3], atol = 9e-2)

# The parameters are a bit off, so we reiterate another SINDy term to get closer to the ground truth
# Create function
unknown_sys = ODESystem(Ψ)
unknown_eq = ODEFunction(unknown_sys)

# Build a ODE for the estimated system
function approx(du, u, p, t)
    # Add SINDy Term
    α, δ, β, γ = p
    z = unknown_eq(u, [β; γ], t)
    du[1] = α*u[1] + z[1]
    du[2] = -δ*u[2] + z[2]
end
@info "Simulate system"
# Create the approximated problem and solution
ps = [p_[[1,4]]; p̂]
a_prob = ODEProblem(approx, u0, tspan, ps)
a_solution = solve(a_prob, Vern7(), abstol=1e-12, reltol=1e-12, saveat = solution.t)
@test norm(a_solution-solution, 2) < 5e-1
@test norm(a_solution-solution, Inf) < 1.5e-1

@info "Finished"
