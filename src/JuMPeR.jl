#############################################################################
# JuMPeR
# Julia for Mathematical Programming - extension for Robust Optimization
# See http://github.com/IainNZ/JuMPeR.jl
#############################################################################

module JuMPeR

import JuMP.GenericAffExpr, JuMP.JuMPConstraint, JuMP.GenericRangeConstraint
import JuMP.sense, JuMP.rhs
import JuMP.IndexedVector, JuMP.addelt, JuMP.isexpr
import JuMP.string_intclamp
importall JuMP

import Base.dot

export RobustModel, Uncertain, UAffExpr, FullAffExpr, @defUnc, solveRobust
export UncConstraint, UncSetConstraint, printRobust
export setAdapt!

# JuMP rexports
export
# Objects
    Model, Variable, AffExpr, QuadExpr, LinearConstraint, QuadConstraint, MultivarDict,
# Functions
    # Relevant to all
    print,show,
    # Model related
    getNumVars, getNumConstraints, getObjectiveValue, getObjective,
    getObjectiveSense, setObjectiveSense, writeLP, writeMPS, setObjective,
    addConstraint, addVar, addVars, solve, copy,
    # Variable
    setName, getName, setLower, setUpper, getLower, getUpper,
    getValue, setValue, getDual,
    # Expressions and constraints
    affToStr, quadToStr, conToStr, chgConstrRHS,
    # Macros and support functions
    @addConstraint, @defVar, 
    @defConstrRef, @setObjective, addToExpression


#############################################################################
# RobustData contains all extensions to the base JuMP model type
type RobustData
    # Variable-Uncertain mixed constraints
    uncertainconstr
    # Oracles associated with each uncertainconstr
    oracles
    # Uncertain-only constraints
    uncertaintyset
    
    # Uncertainty data
    numUncs::Int
    uncNames::Vector{String}
    uncLower::Vector{Float64}
    uncUpper::Vector{Float64}

    # Adaptability
    adapt_type::Dict{Int,Symbol}
    adapt_on::Dict{Int,Vector}

    defaultOracle
end
RobustData() = RobustData(  Any[],Any[],Any[],
                            0,String[],Float64[],Float64[],
                            Dict{Int,Symbol}(), Dict{Int,Vector}(),
                            PolyhedralOracle())

function RobustModel(;solver=nothing)
    m = Model(solver=solver)
    m.ext[:Robust] = RobustData()
    return m
end

function getRobust(m::Model)
    if haskey(m.ext, :Robust)
        return m.ext[:Robust]
    else
        error("This functionality is only available for RobustModels")
    end
end

function printRobust(m::Model)
    rd = getRobust(m)
    # First, display normal model stuff
    print(m)
    println("Uncertain constraints:")
    for c in rd.uncertainconstr
        println(conToStr(c))
    end
    println("Uncertainty set:")
    for uc in rd.uncertaintyset
        println(conToStr(uc))
    end
    for unc in 1:rd.numUncs
        println("$(rd.uncLower[unc]) <= $(rd.uncNames[unc]) <= $(rd.uncUpper[unc])")
    end
end

#############################################################################
# Uncertain
# Similar to JuMP.Variable, has an reference back to the model and an id num
type Uncertain
    m::Model
    unc::Int
end

function Uncertain(m::Model, lower::Number, upper::Number, name::String)
    robdata = getRobust(m)
    robdata.numUncs += 1
    push!(robdata.uncNames, name)
    push!(robdata.uncLower, convert(Float64, lower))
    push!(robdata.uncUpper, convert(Float64, upper))
    return Uncertain(m, robdata.numUncs)
end
Uncertain(m::Model, lower::Number, upper::Number) = Uncertain(m,lower,upper,"")

# Name setter/getters
setName(u::Uncertain, n::String) = (getRobust(u.m).uncNames[u.unc] = n)
function getName(u::Uncertain)
    n = getRobust(u.m).uncNames[u.unc]
    return n == "" ? string("_unc", u.unc) : n
end
print(io::IO, u::Uncertain) = print(io, getName(u))
show( io::IO, u::Uncertain) = print(io, getName(u))


#############################################################################
# Uncertain Affine Expression class
typealias UAffExpr GenericAffExpr{Float64,Uncertain}

UAffExpr() = UAffExpr(Uncertain[],Float64[],0.)
UAffExpr(c::Float64) = UAffExpr(Uncertain[],Float64[],c)
UAffExpr(u::Uncertain, c::Float64) = UAffExpr([u],[c],0.)
UAffExpr(coeffs::Array{Float64,1}) = [UAffExpr(c) for c in coeffs]
zero(::Type{UAffExpr}) = UAffExpr()  # For zeros(UAffExpr, dims...)

print(io::IO, a::UAffExpr) = print(io, affToStr(a))
show( io::IO, a::UAffExpr) = print(io, affToStr(a))

function affToStr(a::UAffExpr, showConstant=true)
    const ZEROTOL = 1e-20

    if length(a.vars) == 0
        if showConstant
            return string_intclamp(a.constant)
        else
            return "0"
        end
    end

    # Get reference to robust part of model
    robdata = getRobust(a.vars[1].m)

    # Collect like terms
    indvec = IndexedVector(Float64, robdata.numUncs)
    for ind in 1:length(a.vars)
        addelt(indvec, a.vars[ind].unc, a.coeffs[ind])
    end

    # Stringify the terms
    elm = 0
    termStrings = Array(UTF8String, 2*length(a.vars))
    for i in 1:indvec.nnz
        idx = indvec.nzidx[i]
        if abs(abs(indvec.elts[idx])-1) <= ZEROTOL
            if elm == 0
                elm += 1
                if indvec.elts[idx] < 0
                    termStrings[1] = "-$(robdata.uncNames[idx])"
                else
                    termStrings[1] = "$(robdata.uncNames[idx])"
                end
            else 
                if indvec.elts[idx] < 0
                    termStrings[2*elm] = " - "
                else
                    termStrings[2*elm] = " + "
                end
                termStrings[2*elm+1] = "$(robdata.uncNames[idx])"
                elm += 1
            end
        elseif abs(indvec.elts[idx]) >= ZEROTOL
            if elm == 0
                elm += 1
                termStrings[1] = "$(string_intclamp(indvec.elts[idx])) $(robdata.uncNames[idx])"
            else 
                if indvec.elts[idx] < 0
                    termStrings[2*elm] = " - "
                else
                    termStrings[2*elm] = " + "
                end
                termStrings[2*elm+1] = "$(string_intclamp(abs(indvec.elts[idx]))) $(robdata.uncNames[idx])"
                elm += 1
            end
        end
    end
    

    if elm == 0
        ret = "0"
    else
        # And then connect them up with +s
        ret = join(termStrings[1:(2*elm-1)])
    end

    if abs(a.constant) >= 0.000001 && showConstant
        if a.constant < 0
            ret = string(ret, " - ", string_intclamp(abs(a.constant)))
        else
            ret = string(ret, " + ", string_intclamp(a.constant))
        end
    end
    return ret
end


#############################################################################
# Full Affine Expression class
# Todo: better name. In my other robust modelling tools I called it
# something like this, but the catch then was that there we only two types of
# affexpr - the one with UAffExpr coefficients = Full, and the UAffExpr itself
typealias FullAffExpr GenericAffExpr{UAffExpr,Variable}

FullAffExpr() = FullAffExpr(Variable[], UAffExpr[], UAffExpr())

# Pretty cool that this is almost the same as normal affExpr
function affToStr(a::FullAffExpr, showConstant=true)
    const ZEROTOL = 1e-20

    # If no variables, hand off to the constant part
    if length(a.vars) == 0
        return showConstant ? affToStr(a.constant) : "0"
    end

    # Get reference to robust part of model
    robdata = getRobust(a.vars[1].m)

    # Stringify the terms - we don't collect like terms
    termStrings = Array(UTF8String, length(a.vars))
    numTerms = 0
    first = true
    for i in 1:length(a.vars)
        numTerms += 1
        uaff = a.coeffs[i]
        varn = getName(a.vars[i])
        prefix = first ? "" : " + "
        # Coefficient expression is a constant
        if length(uaff.vars) == 0
            if abs(uaff.constant) <= ZEROTOL
                # Constant 0 - do not display this term at all
                termStrings[numTerms] = ""
            elseif abs(uaff.constant - 1) <= ZEROTOL
                # Constant +1
                termStrings[numTerms] = first ? varn : " + $varn"
            elseif abs(uaff.constant + 1) <= ZEROTOL
                # Constant -1
                termStrings[numTerms] = first ? "-$varn" : " - $varn"
            else
                # Constant is other than 0, +1, -1 
                if first
                    sign = uaff.constant < 0 ? "-" : ""
                    termStrings[numTerms] = "$sign$(string_intclamp(abs(uaff.constant))) $varn"
                else
                    sign = uaff.constant < 0 ? "-" : "+"
                    termStrings[numTerms] = " $sign $(string_intclamp(abs(uaff.constant))) $varn"
                end
            end
        # Coefficient expression is a single uncertainty
        elseif length(uaff.vars) == 1
            if abs(uaff.constant) <= ZEROTOL && abs(abs(uaff.coeffs[1]) - 1) <= ZEROTOL
                # No constant, so no (...) needed
                termStrings[numTerms] = string(prefix,affToStr(uaff)," ",varn)
            else
                # Constant - need (...)
                termStrings[numTerms] = string(prefix,"(",affToStr(uaff),") ",varn)
            end
        # Coefficient is a more complicated expression
        else
            termStrings[numTerms] = string(prefix,"(",affToStr(uaff),") ",varn)
        end
        first = false
    end

    # And then connect them up with +s
    ret = join(termStrings[1:numTerms], "")
    
    if showConstant
        con_aff = affToStr(a.constant)
        if con_aff != "" && con_aff != "0"
            ret = string(ret," + ",affToStr(a.constant))
        end
    end
    return ret
end

#############################################################################
# UncSetConstraint      Just uncertainties
typealias UncSetConstraint GenericRangeConstraint{UAffExpr}
addConstraint(m::Model, c::UncSetConstraint) = push!(getRobust(m).uncertaintyset, c)

# UncConstraint         Mix of variables and uncertains
typealias UncConstraint GenericRangeConstraint{FullAffExpr}
function addConstraint(m::Model, c::UncConstraint, w=nothing)
    push!(getRobust(m).uncertainconstr,c)
    push!(getRobust(m).oracles, w)
end

#############################################################################
# Adaptability
function setAdapt!(x::Variable, atype::Symbol, uncs::Vector)
    !(atype in [:Affine]) && error("Unrecognized adaptability type '$atype'")
    all_uncs = Uncertain[]
    add_to_list(u::Uncertain)           = (push!(all_uncs, u))
    add_to_list(u::JuMP.JuMPDict{Uncertain}) = (all_uncs=vcat(all_uncs,u.innerArray))
    add_to_list(u::Array{Uncertain})    = (all_uncs=vcat(all_uncs,vec(u)))
    add_to_list{T}(u::T)                = error("Can only depend on Uncertains (tried to adapt on $T)")
    map(add_to_list, uncs)
    rd = getRobust(x.m)
    rd.adapt_type[x.col] = atype
    rd.adapt_on[x.col]   = all_uncs
end
setAdapt!(x::JuMP.JuMPDict{Variable}, atype::Symbol, uncs::Vector) =
    map((v)->setAdapt!(v, atype, uncs), x.innerArray)
setAdapt!(x::Array{Variable}, atype::Symbol, uncs::Vector) =
    map((v)->setAdapt!(v, atype, uncs), x)


#############################################################################
# Operator overloads
include("robustops.jl")

# All functions related to actual solution
include("solve.jl")

# Oracles... to be name changed
include("oracle.jl")

# Macros for more efficient generation
include("robustmacro.jl")

#############################################################################
end  # module
#############################################################################