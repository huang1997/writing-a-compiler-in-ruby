#!/bin/env ruby

require 'set'

$: << File.dirname(__FILE__)

require 'emitter'
require 'parser'
require 'scope'
require 'function'
require 'extensions'
require 'ast'
require 'transform'
require 'print_sexp'

require 'compile_arithmetic'
require 'compile_comparisons'

require 'trace'
require 'stackfence'
require 'saveregs'
require 'splat'

require 'value'

class Compiler
  attr_reader :global_functions
  attr_writer :trace, :stackfence

  # list of all predefined keywords with a corresponding compile-method
  # call & callm are ignored, since their compile-methods require
  # a special calling convention
  @@keywords = Set[
                   :do, :class, :defun, :defm, :if, :lambda,
                   :assign, :while, :index, :bindex, :let, :case, :ternif,
                   :hash, :return,:sexp, :module, :rescue, :incr, :block,
                   :required, :add, :sub, :mul, :div, :eq, :ne,
                   :lt, :le, :gt, :ge,:saveregs, :and, :or,
                   :preturn, :proc, :stackframe, :deref
                  ]

  Keywords = @@keywords

  @@oper_methods = Set[ :<< ]

  def initialize emitter = Emitter.new
    @e = emitter
    @global_functions = {}
    @string_constants = {}
    @global_constants = Set.new
    @global_constants << :false
    @global_constants << :true
    @global_constants << :nil
    @global_constants << :__left
    @classes = {}
    @vtableoffsets = VTableOffsets.new
    @trace = false
  end


  # Outputs nice compiler error messages, similar to
  # the parser (ParserBase#error).
  def error(error_message, current_scope = nil, current_exp = nil)
    if current_exp.respond_to?(:position) && current_exp.position && current_exp.position.lineno
      pos = current_exp.position
      location = " @ #{pos.inspect}"
    elsif @lastpos
      location = " near (after) #{@lastpos}"
    else
      location = ""
    end
    raise "Compiler error: #{error_message}#{location}\n
           current scope: #{current_scope.inspect}\n
           current expression: #{current_exp.inspect}\n"
  end


  # Prints out a warning to the console.
  # Similar to error, but doesn't throw an exception, only prints out a message
  # and any given additional arguments during compilation process to the console.
  def warning(warning_message, *args)
    STDERR.puts("#{warning_message} - #{args.join(',')}")
  end


  # Allocate a symbol
  def intern(scope,sym)
    # FIXME: Do this once, and add an :assign to a global var, and use that for any
    # later static occurrences of symbols.
    Value.new(get_arg(scope,[:sexp,[:call,:__get_symbol, sym.to_s]]),:object)
  end

  # For our limited typing we will in some cases need to do proper lookup.
  # For now, we just want to make %s(index __env__ xxx) mostly treated as
  # objects, in order to ensure that variables accesses that gets rewritten
  # to indirect via __env__ gets treated as object. The exception is
  # for now __env__[0] which contains a stackframe pointer used by
  # :preturn.
  def lookup_type(var, index = nil)
    (var == :__env__ && index != 0) ? :object : nil
  end

  # Returns an argument with its type identifier.
  #
  # If an Array is given, we have a subexpression, which needs to be compiled first.
  # If a Fixnum is given, it's an int ->   [:int, a]
  # If it's a Symbol, its a variable identifier and needs to be looked up within the given scope.
  # Otherwise, we assume it's a string constant and treat it like one.
  def get_arg(scope, a, save = false)
    return compile_exp(scope, a) if a.is_a?(Array)
    return get_arg(scope,:true, save) if a == true 
    return get_arg(scope,:false, save) if a == false
    return Value.new([:int, a]) if (a.is_a?(Fixnum))
    return Value.new([:int, a.to_i]) if (a.is_a?(Float)) # FIXME: uh. yes. This is a temporary hack
    return Value.new([:int, a.to_s[1..-1].to_i]) if (a.is_a?(Symbol) && a.to_s[0] == ?$) # FIXME: Another temporary hack
    if (a.is_a?(Symbol))
      name = a.to_s
      return intern(scope,name[1..-1]) if name[0] == ?:

      arg = scope.get_arg(a)

      # If this is a local variable or argument, we either
      # obtain the argument it is cached in, or we cache it
      # if possible. If we are calling #get_arg to get
      # a target to *save* a value to (assignment), we need
      # to mark it as dirty to ensure we save it back to memory
      # (spill it) if we need to evict the value from the
      # register to use it for something else.

      if arg.first == :lvar || arg.first == :arg || (arg.first == :global && arg.last == :self)
        reg = @e.cache_reg!(name, arg.first, arg.last, save)
        # FIXME: Need to check type

        return Value.new([:reg,reg],:object) if reg
      end

      # FIXME: Check type
      return Value.new(arg, :object)
    end

    warning("nil received by get_arg") if !a
    return strconst(a)
  end

  def strconst(a)
    lab = @string_constants[a]
    if !lab # For any constants in s-expressions
      lab = @e.get_local
      @string_constants[a] = lab
    end
    return Value.new([:addr,lab])
  end

  # Outputs all constants used within the code generated so far.
  # Outputs them as string and global constants, respectively.
  def output_constants
    @e.rodata { @string_constants.each { |c, l| @e.string(l, c) } }
    @e.bss    { @global_constants.each { |c|    @e.bsslong(c) }}
  end


  # Similar to output_constants, but for functions.
  # Compiles all functions, defined so far and outputs the appropriate assembly code.
  def output_functions
    # This is a bit ugly, but handles the case of lambdas or inner
    # functions being added during the compilation... Should probably
    # refactor.
    while f = @global_functions.shift
      name = f[0]
      func = f[1]
      # create a function scope for each defined function and compile it appropriately.
      # also pass it the current global scope for further lookup of variables used
      # within the functions body that aren't defined there (global variables and those,
      # that are defined in the outer scope of the function's)

      fscope = FuncScope.new(func)

      pos = func.body.respond_to?(:position) ? func.body.position : nil
      fname = pos ? pos.filename : nil

      @e.include(fname) do
        # We extract the usage frequency information and pass it to the emitter
        # to inform the register allocation.
        varfreq = func.body.respond_to?(:extra) ? func.body.extra[:varfreq] : []
        @e.func(name, pos, varfreq) do
          minargs = func.minargs

          compile_if(fscope, [:lt, :numargs, minargs],
                     [:sexp,[:call, :printf, 
                             ["ArgumentError: In %s - expected a minimum of %d arguments, got %d\n",
                              name, minargs - 2, [:sub, :numargs,2]]], [:div,1,0] ])

          if !func.rest?
            maxargs = func.maxargs
            compile_if(fscope, [:gt, :numargs, maxargs],
                       [:sexp,[:call, :printf, 
                               ["ArgumentError: In %s - expected a maximum of %d arguments, got %d\n",
                                name, maxargs - 2, [:sub, :numargs,2]]],  [:div,1,0] ])
          end

          if func.defaultvars > 0
            @e.with_stack(func.defaultvars) do 
              func.process_defaults do |arg, index|
                @e.comment("Default argument for #{arg.name.to_s} at position #{2 + index}")
                @e.comment(arg.default.inspect)
                compile_if(fscope, [:lt, :numargs, 1 + index],
                           [:assign, ("#"+arg.name.to_s).to_sym, arg.default],
                           [:assign, ("#"+arg.name.to_s).to_sym, arg.name])
              end
            end
          end

          compile_eval_arg(fscope, func.body)

          @e.comment("Reloading self if evicted:")
          # Ensure %esi is intact on exit, if needed:
          reload_self(fscope)
        end
      end
    end
  end

  # Need to clean up the name to be able to use it in the assembler.
  # Strictly speaking we don't *need* to use a sensible name at all,
  # but it makes me a lot happier when debugging the asm.
  def clean_method_name(name)
    dict = {
      "?" => "__Q",     "!"  => "__X", 
      "[]" => "__NDX",  "==" => "__eq",  
      ">=" => "__ge",   "<=" => "__le", 
      "<"  => "__lt",   ">"  => "__gt",
      "/"  => "__div",  "*"  => "__mul",
      "+"  => "__plus", "-"  => "__minus"}

    cleaned = name.to_s.gsub(Regexp.new('>=|<=|==|[\?!<>+\-\/\*]')) do |match|
      dict[match.to_s]
    end

    cleaned = cleaned.split(Regexp.new('')).collect do |c|
      if c.match(Regexp.new('[a-zA-Z0-9_]'))
        c
      else
        "__#{c[0].ord.to_s(16)}"
      end
    end.join
    return cleaned
  end

  # Handle e.g. Tokens::Atom, which is parsed as (deref Tokens Atom)
  #
  # For now we are assuming statically resolvable chains, and not
  # tested multi-level dereference (e.g. Foo::Bar::Baz)
  #
  def compile_deref(scope, left, right)
    cscope = scope.find_constant(left)
    raise "Unable to resolve: #{left}::#{right} statically (FIXME)" if !cscope || !cscope.is_a?(ClassScope)
    get_arg(cscope,right)
  end


  # Compiles a function definition.
  # Takes the current scope, in which the function is defined,
  # the name of the function, its arguments as well as the body-expression that holds
  # the actual code for the function's body.
  #
  # Note that compile_defun is now only accessed via s-expressions
  def compile_defun(scope, name, args, body)
    f = Function.new(name,args, body,scope)
    name = clean_method_name(name)

    # add function to the global list of functions defined so far
    @global_functions[name] = f

    # a function is referenced by its name (in assembly this is a label).
    # wherever we encounter that name, we really need the adress of the label.
    # so we mark the function with an adress type.
    return Value.new([:addr, clean_method_name(name)])
  end

  # Compiles a method definition and updates the
  # class vtable.
  def compile_defm(scope, name, args, body)
    scope = scope.class_scope

    # FIXME: Replace "__closure__" with the block argument name if one is present
    f = Function.new(name,[:self,:__closure__]+args, body, scope) # "self" is "faked" as an argument to class methods

    @e.comment("method #{name}")


    cleaned = clean_method_name(name)
    fname = "__method_#{scope.name}_#{cleaned}"
    scope.set_vtable_entry(name, fname, f)

    # Save to the vtable.
    v = scope.vtable[name]
    compile_eval_arg(scope,[:sexp, [:call, :__set_vtable, [:self,v.offset, fname.to_sym]]])
    
    # add the method to the global list of functions defined so far
    # with its "munged" name.
    @global_functions[fname] = f
    
    # This is taken from compile_defun - it does not necessarily make sense for defm
    return Value.new([:addr, clean_method_name(fname)])
  end

  # Compiles an if expression.
  # Takes the current (outer) scope and two expressions representing
  # the if and else arm.
  # If no else arm is given, it defaults to nil.
  def compile_if(scope, cond, if_arm, else_arm = nil)
    @e.comment("if: #{cond.inspect}")
    res = compile_eval_arg(scope, cond)
    l_else_arm = @e.get_local + "_else"
    l_end_if_arm = @e.get_local + "_endif"

    if res && res.type == :object
      @e.save_result(res)
      @e.cmpl(@e.result_value, "nil")
      @e.je(l_else_arm)
      @e.cmpl(@e.result_value, "false")
      @e.je(l_else_arm)
    else
      @e.jmp_on_false(l_else_arm, res)
    end

    @e.comment("then: #{if_arm.inspect}")
    ifret = compile_eval_arg(scope, if_arm)
    @e.jmp(l_end_if_arm) if else_arm
    @e.comment("else: #{else_arm.inspect}")
    @e.local(l_else_arm)
    elseret = compile_eval_arg(scope, else_arm) if else_arm
    @e.local(l_end_if_arm) if else_arm

    # At the moment, we're not keeping track of exactly what might have gone on
    # in the if vs. else arm, so we need to assume all bets are off.
    @e.evict_all

    # We only return a specific type if there's either only an "if"
    # expression, or both the "if" and "else" expressions have the
    # same type.
    #
    type = nil
    if ifret && (!elseret || ifret.type == elseret.type)
      type = ifret.type
    end

    return Value.new([:subexpr], type)
  end

  def compile_return(scope, arg = nil)
    @e.save_result(compile_eval_arg(scope, arg)) if arg
    @e.leave
    @e.ret
    Value.new([:subexpr])
  end

  def compile_rescue(scope, *args)
    warning("RESCUE is NOT IMPLEMENTED")
    Value.new([:subexpr])
  end

  def compile_incr(scope, left, right)
    compile_exp(scope, [:assign, left, [:add, left, right]])
  end

  # Shortcircuit 'left && right' is equivalent to 'if left; right; end'
  def compile_and scope, left, right
    compile_if(scope, left, right)
  end

  def compile_or scope, left, right
    @e.comment("compile_or: #{left.inspect} || #{right.inspect}")
    # FIXME: Eek. need to make sure variables are assigned for these. Turn it into a rewrite?
    compile_eval_arg(scope,[:assign, :__left, left])
    compile_if(scope, :__left, :__left, right)
  end

  # Compiles the ternary if form (cond ? then : else) 
  # It may be better to transform this into the normal
  # if form in the tree.
  def compile_ternif(scope, cond, alt)
    if alt.is_a?(Array) && alt[0] == :ternalt
      if_arm = alt[1]
      else_arm = alt[2]
    else
      if_arm = alt
    end
    compile_if(scope,cond,if_arm,else_arm)
  end

  def compile_hash(scope, *args)
    pairs = []
    args.collect do |pair|
      if !pair.is_a?(Array) || pair[0] != :pair
        error("Literal Hash must contain key value pairs only",scope,args)
      end
      pairs << pair[1]
      pairs << pair[2]
    end
    compile_callm(scope, :Hash, :new, pairs)
  end

  def compile_case(scope, *args)
#    error(":case not implemented yet", scope, [:case]+args)
    # FIXME:
    # Implement like this: compile_eval_arg
    # save the register, and loop over the "when"'s.
    # Compile each of the "when"'s as "if"'s where the value
    # is loaded from the stack and compared with the value
    # (or values) in the when clause


    # experimental (need to look into saving to register etc..):
    # but makes it compile all the way through for now...

    @e.comment("compiling case expression")
    compare_exp = args.first

    @e.comment("compare_exp: #{compare_exp}")

    args.rest.each do |whens|
      whens.each do |exp| # each when-expression
        test_value = exp[1] # value to test against
        body = exp[2] # body to be executed, if compare_exp === test_value

        @e.comment("test_value: #{test_value.inspect}")
        @e.comment("body: #{body.inspect}")

        # turn case-expression into if.
        compile_if(scope, [:callm, compare_exp, :===, test_value], body)
      end
    end

    return Value.new([:subexpr])
  end

  # Compiles an anonymous function ('lambda-expression').
  # Simply calls compile_defun, only, that the name gets generated
  # by the emitter via Emitter#get_local.
  def compile_lambda(scope, args=nil, body=nil)
    e = @e.get_local
    body ||= []
    args ||= []
    # FIXME: Need to use a special scope object for the environment,
    # including handling of self. 
    # Note that while compiled with compile_defun, the calling convetion
    # is that of a method. However we have the future complication of
    # handling instance variables in closures, which is rather painful.
    r = compile_defun(scope, e, [:self,:__closure__]+args,[:let,[]]+body)
    r
  end


  def compile_stackframe(scope)
    @e.comment("Stack frame")
    Value.new([:reg,:ebp])
  end

  # "Special" return for `proc` and bare blocks
  # to exit past Proc#call.
  def compile_preturn(scope, arg = nil)
    @e.comment("preturn")

    @e.save_result(compile_eval_arg(scope, arg)) if arg
    @e.pushl(:eax)

    # We load the return address pre-saved in __stackframe__ on creation of the proc.
    # __stackframe__ is automatically added to __env__ in `rewrite_let_env`

    ret = compile_eval_arg(scope,[:index,:__env__,0])

    @e.movl(ret,:ebp)
    @e.popl(:eax)
    @e.leave
    @e.ret
    @e.evict_all
    return Value.new([:subexpr])
  end

  # To compile `proc`, and anonymous blocks
  # See also #compile_lambda
  def compile_proc(scope, args=nil, body=nil)
    e = @e.get_local
    body ||= []
    args ||= []

    r = compile_defun(scope, e, [:self,:__closure__]+args,[:let,[]]+body)
    r
  end


  # Compiles and evaluates a given argument within a given scope.
  def compile_eval_arg(scope, arg)
    if arg.respond_to?(:position) && arg.position != nil
      pos = arg.position.inspect
      if pos != @lastpos
        @e.lineno(arg.position)
        trace(arg.position,arg)
      end
      @lastpos = pos
    end
    args = get_arg(scope,arg)
    error("Unable to find '#{arg.inspect}'") if !args
    atype = args[0]
    aparam = args[1]
    if atype == :ivar
      ret = compile_eval_arg(scope, :self)
      @e.load_instance_var(ret, aparam)
      # FIXME: Verify type of ivar
      return Value.new(@e.result_value, :object)
    elsif atype == :possible_callm
      return Value.new(compile_eval_arg(scope,[:callm,:self,aparam,[]]), :object)
    end

    return Value.new(@e.load(atype, aparam), args.type)
  end


  # Compiles an assignment statement.
  def compile_assign(scope, left, right)
    # transform "foo.bar = baz" into "foo.bar=(baz) - FIXME: Is this better handled in treeoutput.rb?
    # Also need to handle :call equivalently.
    if left.is_a?(Array) && left[0] == :callm && left.size == 3 # no arguments
      return compile_callm(scope, left[1], (left[2].to_s + "=").to_sym, right)
    end

    source = compile_eval_arg(scope, right)
    atype = nil
    aparam = nil
    @e.save_register(source) do
      args = get_arg(scope,left,:save)
      atype = args[0]  # FIXME: Ugly, but the compiler can't yet compile atype,aparem = get_arg ...
      aparam = args[1]
      atype = :addr if atype == :possible_callm
    end

    if atype == :addr
      scope.add_constant(aparam)
      @global_constants << aparam
    elsif atype == :ivar
      # FIXME:  The register allocation here
      # probably ought to happen in #save_to_instance_var
      @e.pushl(source)
      ret = compile_eval_arg(scope, :self)
      @e.with_register do |reg|
        @e.popl(reg)
        @e.save_to_instance_var(reg, ret, aparam)
      end
      # FIXME: Need to check for "special" ivars
      return Value.new([:subexpr], :object)
    end

    if !(@e.save(atype, source, aparam))
      err_msg = "Expected an argument on left hand side of assignment - got #{atype.to_s}, (left: #{left.inspect}, right: #{right.inspect})"
      error(err_msg, scope, [:assign, left, right]) # pass current expression as well
    end
    return Value.new([:subexpr])
  end


  # Push arguments onto the stack
  def push_args(scope,args, offset = 0)
    args.each_with_index do |a, i|
      param = compile_eval_arg(scope, a)
      @e.save_to_stack(param, i + offset)
    end
  end


  # Compiles a function call.
  # Takes the current scope, the function to call as well as the arguments
  # to call the function with.
  def compile_call(scope, func, args, block = nil)
    return compile_yield(scope, args, block) if func == :yield

    # This is a bit of a hack. get_arg will also be called from
    # compile_eval_arg below, but we need to know if it's a callm
    fargs = get_arg(scope, func)

    return compile_super(scope, args,block) if func == :super
    return compile_callm(scope,:self, func, args,block) if fargs && fargs[0] == :possible_callm

    args = [args] if !args.is_a?(Array)
    @e.caller_save do
      handle_splat(scope, args) do |args,splat|
        @e.comment("ARGS: #{args.inspect}; #{splat}")
        @e.with_stack(args.length, !splat) do
          @e.pushl(@e.scratch)
          push_args(scope, args,1)
          @e.popl(@e.scratch)
          @e.call(compile_eval_arg(scope, func))
        end
      end
    end

    @e.evict_regs_for(:self)
    reload_self(scope)
    return Value.new([:subexpr])
  end

  # If adding type-tagging, this is the place to do it.
  # In the case of type tagging, the value in %esi
  # would be matched against the suitable type tags
  # to determine the class, instead of loading the class
  # from the first long of the object.
  def load_class(scope)
    @e.load_indirect(:esi, :eax)
  end

  # Load the super-class pointer
  def load_super(scope)
    @e.load_instance_var(:eax, 3)
  end
                

  # if we called a method on something other than self,
  # or a function, we have or may have clobbered %esi,
  # so lets reload it.
  def reload_self(scope)
    t,a = get_arg(scope,:self)
  end

  # Yield to the supplied block
  def compile_yield(scope, args, block)
    @e.comment("yield")
    args ||= []
    compile_callm(scope, :__closure__, :call, args, block)
  end

  def compile_callm_args(scope, ob, args)
    handle_splat(scope,args) do |args, splat|
      @e.with_stack(args.length+1, !splat) do
        # we're for now going to assume that %ebx is likely
        # to get clobbered later in the case of a splat,
        # so we store it here until it's time to call the method.
        @e.pushl(@e.scratch)
        
        ret = compile_eval_arg(scope, ob)
        @e.save_to_stack(ret, 1)
        args.each_with_index do |a,i|
          param = compile_eval_arg(scope, a)
          @e.save_to_stack(param, i+2)
        end
        
        # Pull the number of arguments off the stack
        @e.popl(@e.scratch)
        yield  # And give control back to the code that actually does the call.
      end
    end
  end


  # Compiles a super method call
  #
  def compile_super(scope, args, block = nil)
    method = scope.method.name
    @e.comment("super #{method.inspect}")
    trace(nil,"=> super #{method.inspect}\n")
    ret = compile_callm(scope, :self, method, args, block, true)
    trace(nil,"<= super #{method.inspect}\n")
    ret
  end

  # Compiles a method call to an object.
  # Similar to compile_call but with an additional object parameter
  # representing the object to call the method on.
  # The object gets passed to the method, which is just another function,
  # as the first parameter.
  def compile_callm(scope, ob, method, args, block = nil, do_load_super = false)
    # FIXME: Shouldn't trigger - probably due to the callm rewrites
    return compile_yield(scope, args, block) if method == :yield and ob == :self

    @e.comment("callm #{ob.inspect}.#{method.inspect}")
    trace(nil,"=> callm #{ob.inspect}.#{method.inspect}\n")

    stackfence do
      args ||= []
      args = [args] if !args.is_a?(Array) # FIXME: It's probably better to make the parser consistently pass an array
      args = [block ? block : 0] + args

      off = @vtableoffsets.get_offset(method)
      if !off
        # Argh. Ok, then. Lets do send
        off = @vtableoffsets.get_offset(:__send__)
        args.insert(1,":#{method}".to_sym)
        warning("WARNING: No vtable offset for '#{method}' (with args: #{args.inspect}) -- you're likely to get a method_missing")
        #error(err_msg, scope, [:callm, ob, method, args])
        m = off
      else
        m = "__voff__#{clean_method_name(method)}"
      end

      @e.caller_save do
        compile_callm_args(scope, ob, args) do
          if ob != :self
            @e.load_indirect(@e.sp, :esi) 
          else
            @e.comment("Reload self?")
            reload_self(scope)
          end

          load_class(scope) # Load self.class into %eax
          load_super(scope) if do_load_super
          
          @e.callm(m)
          if ob != :self
            @e.comment("Evicting self") 
            @e.evict_regs_for(:self) 
          end
        end
      end
    end

    @e.comment("callm #{ob.to_s}.#{method.to_s} END")
    trace(nil,"<= callm #{ob.to_s}.#{method.to_s}\n")

    return Value.new([:subexpr], :object)
  end


  # Compiles a do-end block expression.
  def compile_do(scope, *exp)
    if exp.length == 0
      exp = [:nil]
    end

    exp.each { |e| source=compile_eval_arg(scope, e); @e.save_result(source); }
    return Value.new([:subexpr])
  end

  # :sexp nodes are just aliases for :do nodes except
  # that code that rewrites the tree and don't want to
  # affect %s() escaped code should avoid descending
  # into :sexp nodes.
  def compile_sexp(scope, *exp)
    # We explicitly delete the type information for :sexp nodes for now.
    Value.new(compile_do(SexpScope.new(scope), *exp), nil)
  end

  # :block nodes are "begin .. end" blocks or "do .. end" blocks
  # (which doesn't really matter to the compiler, just the parser
  # - what matters is that if it stands on it's own it will be
  # "executed" immediately; otherwise it should be treated like
  # a :lambda more or less. 
  #
  # FIXME: Since we don't implement "rescue" yet, we'll just
  # treat it as a :do, which is likely to cause lots of failures
  def compile_block(scope, *exp)
    compile_do(scope, *exp[1])
  end


  # Compiles an 8-bit array indexing-expression.
  # Takes the current scope, the array as well as the index number to access.
  def compile_bindex(scope, arr, index)
    source = compile_eval_arg(scope, arr)
    @e.pushl(source)
    source = compile_eval_arg(scope, index)
    r = @e.with_register do |reg|
      @e.popl(reg)
      @e.save_result(source)
      @e.addl(@e.result_value, reg)
    end
    return Value.new([:indirect8, r])
  end

  # Compiles a 32-bit array indexing-expression.
  # Takes the current scope, the array as well as the index number to access.
  def compile_index(scope, arr, index)
    source = compile_eval_arg(scope, arr)
    r = @e.with_register do |reg|
      @e.movl(source, reg)
      @e.pushl(reg)
      
      source = compile_eval_arg(scope, index)
      @e.save_result(source)
      @e.sall(2, @e.result_value)
      @e.popl(reg)
      @e.addl(@e.result_value, reg)
    end
    return Value.new([:indirect, r], lookup_type(arr,index))
  end


  # Compiles a while loop.
  # Takes the current scope, a condition expression as well as the body of the function.
  def compile_while(scope, cond, body)
    @e.loop do |br|
      var = compile_eval_arg(scope, cond)
    if var && var.type == :object
      @e.save_result(var)
      @e.cmpl(@e.result_value, "nil")
      @e.je(br)
      @e.cmpl(@e.result_value, "false")
      @e.je(br)
    else
      @e.jmp_on_false(br, var)
    end

#      @e.jmp_on_false(br)
      compile_exp(scope, body)
    end
    return Value.new([:subexpr])
  end

  # Compiles a let expression.
  # Takes the current scope, a list of variablenames as well as a list of arguments.
  def compile_let(scope, varlist, *args)
    vars = {}
    
    varlist.each_with_index {|v, i| vars[v]=i}
    ls = LocalVarScope.new(vars, scope)
    if vars.size > 0
      # We brutally handle aliasing (for now) by
      # simply evicting / spilling all allocated
      # registers with overlapping names. An alternative
      # is to give each variable a unique id
      @e.evict_regs_for(varlist)
      @e.with_local(vars.size) { compile_do(ls, *args) }
      @e.evict_regs_for(varlist)
    else
      compile_do(ls, *args)
    end
    return Value.new([:subexpr])
  end

  def compile_module(scope,name, *exps)
    # FIXME: This is a cop-out that will cause horrible
    # crashes - they are not the same (though nearly)
    compile_class(scope,name, *exps)
  end

  # Compiles a class definition.
  # Takes the current scope, the name of the class as well as a list of expressions
  # that belong to the class.
  def compile_class(scope, name,superclass, *exps)
    superc = name == :Class ? nil : @classes[superclass]
    cscope = scope.find_constant(name)

    @e.comment("=== class #{cscope.name} ===")


    @e.evict_regs_for(:self)


    name = cscope.name.to_sym
    # The check for :Class and :Kernel is an "evil" temporary hack to work around the bootstrapping
    # issue of creating these class objects before Object is initialized. A better solution (to avoid
    # demanding an explicit order would be to clear the Object constant and make sure __new_class_object
    #does not try to deref a null pointer
    #
    sscope = (name == superclass or name == :Class or name == :Kernel) ? nil : @classes[superclass]

    ssize = sscope ? sscope.klass_size : nil
    ssize = 0 if ssize.nil?
    compile_exp(scope, [:assign, name.to_sym, [:sexp,[:call, :__new_class_object, [cscope.klass_size,superclass,ssize]]]])

    @global_constants << name

    # In the context of "cscope", "self" refers to the Class object of the newly instantiated class.
    # Previously we used "@instance_size" directly instead of [:index, :self, 1], but when fixing instance
    # variable handling and adding offsets to avoid overwriting instance variables in the superclass,
    # this broke, as obviously we should not be able to directly mess with the superclass's instance
    # variables, so we're intentionally violating encapsulation here.

    compile_exp(cscope, [:assign, [:index, :self, 1], cscope.instance_size])

    # We need to store the "raw" name here, rather than a String object,
    # as String may not have been initialized yet
    compile_exp(cscope, [:assign, [:index, :self, 2], name.to_s])

    exps.each do |e|
      addr = compile_do(cscope, *e)
    end

    @e.comment("=== end class #{name} ===")
    return Value.new([:global, name], :object)
  end

  # Put at the start of a required file, to allow any special processing
  # before/after 
  def compile_required(scope,exp)
    @e.include(exp.position.filename) do
      compile_exp(scope,exp)
    end
  end

  # General method for compiling expressions.
  # Calls the specialized compile methods depending of the
  # expression to be compiled (e.g. compile_if, compile_call, compile_let etc.).
  def compile_exp(scope, exp)
    return Value.new([:subexpr]) if !exp || exp.size == 0

    pos = exp.position rescue nil
    @e.lineno(pos) if pos
    trace(pos,exp)

    # check if exp is within predefined keywords list
    if(@@keywords.include?(exp[0]))
      return self.send("compile_#{exp[0].to_s}", scope, *exp.rest)
    elsif @@oper_methods.member?(exp[0])
      return compile_callm(scope, exp[1], exp[0], exp[2..-1])
    else
      return compile_call(scope, exp[1], exp[2],exp[3]) if (exp[0] == :call)
      return compile_callm(scope, exp[1], exp[2], exp[3], exp[4]) if (exp[0] == :callm)
      return compile_call(scope, exp[0], exp.rest) if (exp.is_a? Array)
    end

    warning("Somewhere calling #compile_exp when they should be calling #compile_eval_arg? #{exp.inspect}")
    res = compile_eval_arg(scope, exp[0])
    @e.save_result(res)
    return Value.new([:subexpr])
  end


  # Compiles the main function, where the compiled programm starts execution.
  def compile_main(exp)
    @e.main(exp.position.filename) do
      # We should allow arguments to main
      # so argc and argv get defined, but
      # that is for later.
      compile_eval_arg(@global_scope, exp)
    end
  end


  # We need to ensure we find the maximum
  # size of the vtables *before* we compile
  # any of the classes
  #
  # Consider whether to check :call/:callm nodes as well, though they
  # will likely hit method_missing
  def alloc_vtable_offsets(exp)
    exp.depth_first(:defm) do |defun|
      @vtableoffsets.alloc_offset(defun[1])
      :skip
    end

    @vtableoffsets.vtable.each do |name, off|
      @e.emit(".equ   __voff__#{clean_method_name(name)}, #{off*4}")
    end

    classes = 0
    exp.depth_first(:class) { |c| classes += 1; :skip }
    #warning("INFO: Max vtable offset when compiling is #{@vtableoffsets.max} in #{classes} classes, for a total vtable overhead of #{@vtableoffsets.max * classes * 4} bytes")
  end
  
  # When we hit a vtable slot for a method that doesn't exist for
  # the current object/class, we call method_missing. However, method
  # missing needs the symbol of the method that was being called.
  # 
  # To handle that, we insert the address of a "thunk" instead of
  # the real method missing. The thunk is a not-quite-function that
  # adjusts the stack to prepend the symbol matching the current
  # vtable slot and then jumps straight to __method_missing, instead
  # of wasting extra stack space and time on copying the objects.
  def output_vtable_thunks
    @vtableoffsets.vtable.each do |name,_|
      @e.label("__vtable_missing_thunk_#{clean_method_name(name)}")
      # FIXME: Call get_symbol for these during initalization
      # and then load them from a table instead.
      res = compile_eval_arg(@global_scope, ":#{name.to_s}".to_sym)
      @e.with_register do |reg|
        @e.popl(reg)
        @e.pushl(res)
        @e.pushl(reg)
      end
      @e.jmp("__method_missing")
    end
    @e.label("__base_vtable")
    # For ease of implementation of __new_class_object we
    # pad this with the number of class ivar slots so that the
    # vtable layout is identical as for a normal class
    ClassScope::CLASS_IVAR_NUM.times { @e.long(0) }
    @vtableoffsets.vtable.to_a.sort_by {|e| e[1] }.each do |e|
      @e.long("__vtable_missing_thunk_#{clean_method_name(e[0])}")
    end
  end

  # Starts the actual compile process.
  def compile exp
    alloc_vtable_offsets(exp)
    compile_main(exp)

    # after the main function, we ouput all functions and constants
    # used and defined so far.
    output_functions
    output_vtable_thunks
    output_constants
  end
end

if __FILE__ == $0
  dump = ARGV.include?("--parsetree")
  norequire = ARGV.include?("--norequire") # Don't process require's statically - compile them instead
  trace = ARGV.include?("--trace")
  stackfence = ARGV.include?("--stackfence")
  transform = !ARGV.include?("--notransform")
  nostabs = ARGV.include?("--nostabs")

  # Option to not rewrite the parse tree (breaks compilation, but useful for debugging of the parser)
  OpPrec::TreeOutput.dont_rewrite if ARGV.include?("--dont-rewrite")


  # check remaining arguments, if a filename is given.
  # if not, read from STDIN.
  input_source = STDIN
  ARGV.each do |arg|
    if File.exists?(arg)
      input_source = File.open(arg, "r")
      STDERR.puts "reading from file: #{arg}"
      break
    end
  end

  s = Scanner.new(input_source)
  prog = nil
  
  begin
    parser = Parser.new(s, {:norequire => norequire})
    prog = parser.parse
  rescue Exception => e
    STDERR.puts "#{e.message}"
    # FIXME: The position ought to come from the parser, as should the rest, since it could come
    # from a 'require'd file, in which case the fragment below means nothing.
    STDERR.puts "Failed at line #{s.lineno} / col #{s.col} / #{s.filename}  before:\n"
    buf = ""
    while s.peek && buf.size < 100
      buf += s.get
    end
    STDERR.puts buf
  end
  
  if prog
    e = Emitter.new
    e.debug == nil if nostabs

    c = Compiler.new(e)
    c.trace = true if trace
    c.stackfence = true if stackfence

    c.preprocess(prog) if transform

    if dump
      print_sexp prog
      exit
    end
    
    c.compile(prog)
  end
end

