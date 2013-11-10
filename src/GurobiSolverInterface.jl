# GurobiMathProgInterface
# Standardized MILP interface

export GurobiSolver

type GurobiMathProgModel <: AbstractMathProgModel
    inner::Model
    last_op_type::Symbol  # To support arbitrary order of addVar/addCon
                          # Two possibilities :Var :Con
end
function GurobiMathProgModel(;options...)
   env = Env()
   for (name,value) in options
       setparam!(env, string(name), value)
   end
   m = GurobiMathProgModel(Model(env,""), :Con)
   return m
end


immutable GurobiSolver <: AbstractMathProgSolver
    options
end
GurobiSolver(;kwargs...) = GurobiSolver(kwargs)
model(s::GurobiSolver) = GurobiMathProgModel(;s.options...)

# Unimplemented
# function loadproblem!(m, filename)

function loadproblem!(m::GurobiMathProgModel, A, collb, colub, obj, rowlb, rowub, sense)
  reset_model!(m.inner)
  add_cvars!(m.inner, float(obj), float(collb), float(colub))
  update_model!(m.inner)

  neginf = typemin(eltype(rowlb))
  posinf = typemax(eltype(rowub))

  # check if we have any range constraints
  # to properly support these, we will need to keep track of the 
  # slack variables automatically added by gurobi.
  rangeconstrs = any((rowlb .!= rowub) & (rowlb .> neginf) & (rowub .< posinf))
  if rangeconstrs
      warn("Julia Gurobi interface doesn't properly support range (two-sided) constraints. See Gurobi.jl issue #14")
      add_rangeconstrs!(m.inner, float(A), float(rowlb), float(rowub))
  else
      b = Array(Float64,length(rowlb))
      senses = Array(Cchar,length(rowlb))
      for i in 1:length(rowlb)
          if rowlb[i] == rowub[i]
              senses[i] = '='
              b[i] = rowlb[i]
          elseif rowlb[i] > neginf
              senses[i] = '>'
              b[i] = rowlb[i]
          else
              @assert rowub[i] < posinf
              senses[i] = '<'
              b[i] = rowub[i]
          end
      end
      add_constrs!(m.inner, float(A), senses, b)
  end
  
  update_model!(m.inner)
  setsense!(m,sense)
end

writeproblem(m::GurobiMathProgModel, filename::String) = write_model(m.inner, filename)

getvarLB(m::GurobiMathProgModel)     = get_dblattrarray (m.inner, "LB", 1, num_vars(m.inner))
setvarLB!(m::GurobiMathProgModel, l) = set_dblattrarray!(m.inner, "LB", 1, num_vars(m.inner), l)

getvarUB(m::GurobiMathProgModel)     = get_dblattrarray (m.inner, "UB", 1, num_vars(m.inner))
setvarUB!(m::GurobiMathProgModel, u) = set_dblattrarray!(m.inner, "UB", 1, num_vars(m.inner), u)

function getconstrLB(m::GurobiMathProgModel)
    sense = get_charattrarray(m.inner, "Sense", 1, num_constr(m.inner))
    ret   = get_dblattrarray(m.inner, "RHS", 1, num_constr(m.inner))
    for i = 1:num_constr(m.inner)
        if sense == '>' || sense == '='
            # Do nothing
        else
            # LEQ constraint, so LB is -Inf
            ret[i] = -Inf
        end
     end
     return ret
end
function setconstrLB!(m::GurobiMathProgModel, lb)
    sense = get_charattrarray(m.inner, "Sense", 1, num_constr(m.inner))
    for i = 1:num_constr(m.inner)
        if sense == '>' || sense == '='
            # Do nothing
        elseif sense == '<' && lb[i] != -Inf
            # LEQ constraint with non-NegInf LB implies a range
            error("Tried to set LB != -Inf on a LEQ constraint (index $i)")
        end
    end
    set_dblattrarray!(m.inner, "RHS", 1, num_constr(m.inner), lb)
end
function getconstrUB(m::GurobiMathProgModel)
    sense = get_charattrarray(m.inner, "Sense", 1, num_constr(m.inner))
    ret   = get_dblattrarray(m.inner, "RHS", 1, num_constr(m.inner))
    for i = 1:num_constr(m.inner)
        if sense == '<' || sense == '='
            # Do nothing
        else
            # GEQ constraint, so UB is +Inf
            ret[i] = +Inf
        end
    end
    return ret
end
function setconstrUB!(m::GurobiMathProgModel, ub)
    sense = get_charattrarray(m.inner, "Sense", 1, num_constr(m.inner))
    for i = 1:num_constr(m.inner)
        if sense == '<' || sense == '='
            # Do nothing
        elseif sense == '>' && ub[i] != -Inf
            # GEQ constraint with non-Inf UB implies a range
            error("Tried to set UB != +Inf on a GEQ constraint (index $i)")
        end
    end
    set_dblattrarray!(m.inner, "RHS", 1, num_constr(m.inner), ub)
end

getobj(m::GurobiMathProgModel)     = get_dblattrarray (m.inner, "Obj", 1, num_vars(m.inner)   )
setobj!(m::GurobiMathProgModel, c) = set_dblattrarray!(m.inner, "Obj", 1, num_vars(m.inner), c)

function addvar!(m::GurobiMathProgModel, constridx, constrcoef, l, u, objcoef)
    if m.last_op_type == :Con
        updatemodel!(m)
        m.last_op_type = :Var
    end
    add_var!(m.inner, length(constridx), constridx, float(constrcoef), objcoef, l, u, GRB_CONTINUOUS)
end
function addvar!(m::GurobiMathProgModel, l, u, objcoef)
    if m.last_op_type == :Con
        updatemodel!(m)
        m.last_op_type = :Var
    end
    add_var!(m.inner, 0, Integer[], Float64[], objcoef, l, u, GRB_CONTINUOUS)
end
function addconstr!(m::GurobiMathProgModel, varidx, coef, lb, ub)
    if m.last_op_type == :Var
        updatemodel!(m)
        m.last_op_type = :Con
    end
    if lb == -Inf
        # <= constraint
        add_constr!(m.inner, varidx, coef, '<', ub)
    elseif ub == +Inf
        # >= constraint
        add_constr!(m.inner, varidx, coef, '>', lb)
    elseif lb == ub
        # == constraint
        add_constr!(m.inner, varidx, coef, '=', lb)
    else
        # Range constraint
        error("Adding range constraints not supported yet.")
    end
end
updatemodel!(m::GurobiMathProgModel) = update_model!(m.inner)

function setsense!(m::GurobiMathProgModel, sense)
  if sense == :Min
    set_sense!(m.inner, :minimize)
  elseif sense == :Max
    set_sense!(m.inner, :maximize)
  else
    error("Unrecognized objective sense $sense")
  end
end
function getsense(m::GurobiMathProgModel)
  v = get_intattr(m.inner, "ModelSense")
  if v == -1 
    return :Max 
  else
    return :Min
  end
end

numvar(m::GurobiMathProgModel)    = num_vars(m.inner)
numconstr(m::GurobiMathProgModel) = num_constrs(m.inner)

optimize!(m::GurobiMathProgModel) = optimize(m.inner)

function status(m::GurobiMathProgModel)
  s = get_status(m.inner)
  if s == :optimal
    return :Optimal
  elseif s == :infeasible
    return :Infeasible
  elseif s == :inf_or_unbd
    return :Unbounded
  elseif s == :iteration_limit || s == :node_limit || s == :time_limit || s == :solution_limit
    return :UserLimit
  else
    error("Internal library error")
  end
end

getobjval(m::GurobiMathProgModel)   = get_objval(m.inner)
getobjbound(m::GurobiMathProgModel) = get_objbound(m.inner)
getsolution(m::GurobiMathProgModel) = get_solution(m.inner)

# TODO
function getconstrsolution(m::GurobiMathProgModel)
  error("GurobiMathProgModel: Not implemented (need to do Ax manually?)")
end

getreducedcosts(m::GurobiMathProgModel) = get_dblattrarray(m.inner, "RC", 1, num_vars(m.inner))
getconstrduals(m::GurobiMathProgModel)  = get_dblattrarray(m.inner, "Pi", 1, num_constrs(m.inner))

getrawsolver(m::GurobiMathProgModel) = m.inner

setvartype!(m::GurobiMathProgModel, vartype) =
    set_charattrarray!(m.inner, "VType", 1, length(vartype), vartype)
function getvartype(m::GurobiMathProgModel) =
    ret = get_charattrarray(m.inner, "VType", 1, num_vars(m.inner))
    for j = 1:num_vars(m.inner)
        if ret[j] == 'B'
            ret[j] = 'I'
        elseif ret[j] == 'S'
            error("Semi-continuous variables not supported by MathProgBase")
        elseif ret[j] == 'N'
            error("Semi-integer variables not supported by MathProgBase")
        end
    end
    return ret
end  
