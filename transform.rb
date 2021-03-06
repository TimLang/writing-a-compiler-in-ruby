
# 
# Parts of the compiler class that mainly transform the source tree
#
# Ideally these will be broken out of the Compiler class at some point
# For now they're moved here to start refactoring.
#

class Compiler
  # This replaces the old lambda handling with a rewrite.
  # The advantage of handling it as a rewrite phase is that it's
  # much easier to debug - it can be turned on and off to 
  # see how the code gets transformed.
  def rewrite_lambda(exp)
    exp.depth_first do |e|
      next :skip if e[0] == :sexp
      if e[0] == :lambda
        args = e[1] || []
        body = e[2] || nil
        e.clear
        e[0] = :do
        e[1] = [:assign, :__tmp_proc, 
          [:defun, @e.get_local,
            [:self,:__closure__,:__env__]+args,
            body]
        ]
        e[2] = [:sexp, [:call, :__new_proc, [:__tmp_proc, :__env__]]]
      end
    end
  end
  

  # Re-write string constants outside %s() to 
  # %s(call __get_string [original string constant])
  def rewrite_strconst(exp)
    exp.depth_first do |e|
      next :skip if e[0] == :sexp
      is_call = e[0] == :call
      e.each_with_index do |s,i|
        if s.is_a?(String)
          lab = @string_constants[s]
          if !lab
            lab = @e.get_local
            @string_constants[s] = lab
          end
          e[i] = [:sexp, [:call, :__get_string, lab.to_sym]]

          # FIXME: This is a horrible workaround to deal with a parser
          # inconsistency that leaves calls with a single argument with
          # the argument "bare" if it's not an array, which breaks with
          # this rewrite.
          e[i] = [e[i]] if is_call && i > 1
        end
      end
    end
  end

  # 1. If I see an assign node, the variable on the left hand is defined
  #    for the remainder of this scope and on any sub-scope.
  # 2. If a sub-scope is lambda, any variable that is _used_ within it
  #    should be transferred from outer active scopes to env.
  # 3. Once all nodes for the current scope have been processed, a :let
  #    node should be added with the remaining variables (after moving to
  #    env).
  # 4. If this is the outermost node, __env__ should be added to the let.

  def in_scopes(scopes, n)
    scopes.reverse.collect {|s| s.member?(n) ? s : nil}.compact
  end

  def push_var(scopes, env, v)
    sc = in_scopes(scopes,v)
    if sc.size == 0 && !env.member?(v) && v.to_s[0] != ?@ &&
        !Compiler::Keywords.member?(v) && v != :nil && v != :self &&
        v!= :true && v != :false  && v.to_s[0] >= ?a
      scopes[-1] << v 
    end
  end

  # FIXME: Rewrite using "depth first"?
  def find_vars(e, scopes, env, in_lambda = false, in_assign = false)
    return [],env, false if !e
    e = [e] if !e.is_a?(Array)
    e.each do |n|
      if n.is_a?(Array)
        if n[0] == :assign
          vars1, env1 = find_vars(n[1],     scopes + [Set.new],env, in_lambda, true)
          vars2, env2 = find_vars(n[2..-1], scopes + [Set.new],env, in_lambda)
          env = env1 + env2
          vars = vars1+vars2
          vars.each {|v| push_var(scopes,env,v) }
        elsif n[0] == :lambda
          vars, env = find_vars(n[2], scopes + [Set.new],env, true)
          n[2] = [:let, vars, *n[2]]
        else
          if    n[0] == :callm then sub = n[3..-1]
          elsif n[0] == :call  then sub = n[2..-1]
          else sub = n[1..-1]
          end
          vars, env = find_vars(sub, scopes, env, in_lambda)
          vars.each {|v| push_var(scopes,env,v) }
        end
      elsif n.is_a?(Symbol)
        sc = in_scopes(scopes,n)
        if sc.size == 0
          push_var(scopes,env,n) if in_assign
        elsif in_lambda
          sc.first.delete(n)
          env << n
        end
      end
    end
    return scopes[-1].to_a, env
  end


  def rewrite_env_vars(exp, env)
    exp.depth_first do |e|
      STDERR.puts e.inspect
      e.each_with_index do |ex, i|
        num = env.index(ex)
        if num
          e[i] = [:index, :__env__, num]
        end
      end
    end
  end

  # Visit the child nodes as follows:
  #  * On first assign, add to the set of variables
  #  * On descending into a :lambda block, add a new "scope"
  #  * On assign inside a block (:lambda node), 
  #    * if the variable is found up the scope chain: Move it to the
  #      "env" set
  #    * otherwise add to the innermost scope
  # Finally:
  #  * Insert :let nodes at the top and at all lambda nodes, if not empty
  #    (add an __env__ var to the topmost :let if the env set is not empty.
  #  * Insert an :env node immediately below the top :let node if the env
  #    set is not empty.
  #    Alt: insert (assign __env__ (array [no-of-env-entries]))  
  # Carry out a second pass:
  #  * For all _uses_ of a variable in the env set, rewrite to
  #    (index [position])
  #    => This can be done in a separate function.

  def rewrite_let_env(exp)
    exp.depth_first(:defm) do |e|
      vars,env= find_vars(e[3],[Set[*e[2]]],Set.new)
      vars -= Set[*e[2]].to_a
      if env.size > 0
        body = e[3]

        rewrite_env_vars(body, env.to_a)
        notargs = env - Set[*e[2]]
        aenv = env.to_a
        extra_assigns = (env - notargs).to_a.collect do |a|
          [:assign, [:index, :__env__, aenv.index(a)], a]
        end
        e[3] = [[:sexp,[:assign, :__env__, [:call, :malloc,  [env.size * 4]]]]]
        e[3].concat(extra_assigns)
        e[3].concat(body)
      end
      # Always adding __env__ here is a waste, but it saves us (for now)
      # to have to intelligently decide whether or not to reference __env__
      # in the rewrite_lambda method
      vars << :__env__
      vars << :__tmp_proc # Used in rewrite_lambda. Same caveats as for __env_

      e[3] = [:let, vars,*e[3]]
      :skip
    end
  end

  def preprocess exp
    rewrite_strconst(exp)
    rewrite_let_env(exp)
    rewrite_lambda(exp)
  end
end
