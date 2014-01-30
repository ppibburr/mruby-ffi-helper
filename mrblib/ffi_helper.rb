unless NilClass.instance_methods.index(:to_ptr)
  class NilClass
    def to_ptr
      FFI::Pointer::NULL
    end
  end
end

module FFI::Helper
  module Typed
    attr_accessor :type, :name, :namespace
    
    def wrap ptr;
      ins = allocate()
      ins.instance_variable_set("@ptr", ptr)
      return ins
    end
    
    def self.included q
      def q.extended c
        c.class_eval do
          define_method :to_ptr do
            @ptr
          end
        end
      end
    end
  end
  
  module HasFunctions
    def function_symbol(&b)
      @func_sym = b
    end
    
    def get_function_symbol(name)
      (@func_sym ||= Proc.new do |n| n.to_sym end).call(name.to_s)
    end
    
    def function(name, args, ret=:void, f_type=nil, invoke = nil, &b)
      target = self
      this = self
      
      if f_type == :class
        target = self.singleton_class
      end

      cbi = nil
      i = -1

      if f_type != :class
        is_method = true
        args = [type].push(*args)
      end
      
      args = args.map do |q|
        i += 1
        if q.is_a?(Hash)
          cbi = i
          next(q[:callback])
        end
        
        if q.is_a?(FFI::Helper::Typed)
          next(q.type)
        end
        
        next(q)
      end
      
      rt = ret.is_a?(FFI::Helper::Typed) ? ret.type : ret
      
      (lib=@namespace::Lib).attach_function((symbol=get_function_symbol(name)),args, rt)
      
      target.class_eval do
        define_method name do |*oa,&cb|
          a = oa
          if cbi
            pre = []
            for i in 0..cbi-1
              pre << oa[i]
            end
            
            post = []
            for i in (cbi)..oa.length-1
              post << oa[i]
            end          
            
            a = [].push(*pre).push(cb).push(*post)  
          end
          
          if is_method
            a = [self.to_ptr].push(*a)
            oa = [self.to_ptr].push(*oa)
          end
          
          while ni=a.index(nil)
            a[ni] = nil.to_ptr
          end
          
          a = a.map do |q|
            q.respond_to?(:to_ptr) ? q.to_ptr : q
          end
          
          if invoke
            result = instance_exec(symbol, *a, &invoke)
          else
            result = lib.send(symbol, *a)
          end
          
          if ret.is_a?(FFI::Helper::Typed)
            result = ret.wrap(result)
          end
          
          result = instance_exec(result, *oa, &b) if b
          return result    
        end
      end
    end  
  end
  
  module Interface
    include Typed
    include HasFunctions
  
    def describe &b
      instance_exec(self, &b) if b
    end
    
    def set_namespace ns
      @namespace = ns
    end
  end
  
  module Object
    include Typed
    include Interface
     
    def constructor name, *args, &b
      function(name, args, self, :class, &b)
    end
  end
  
  module Struct
    include Typed
    
    def layout2 h={}
      o = h.keys.map do |k|
        v = h[k]
        
        if v.is_a?(FFI::Helper::Object)
          (@objects ||={})[k] = v
          next [k,v.type]
        end
        
        next [k,v]
      end.flatten
      
      layout(*o)
    end
  end

  module Namespace
    include HasFunctions
  
    def clib
      self::Lib
    end
    
    def interface name,type, &b
      mod = Module.new
      mod.extend FFI::Helper::Interface
      const_set(name, mod)
      mod.type = type.to_sym
      mod.name = name.to_s 
      mod.namespace = self
      
      clib.typedef :pointer, type
      
      mod.instance_eval(&b) if b
      
      mod      
    end
    
    def object name, type, sc=::Object, &b
      const_set(name, this = Class.new(sc))
      this.extend FFI::Helper::Object
      
      this.type = type.to_sym
      this.name = name.to_s 
      this.namespace = self
      
      clib.typedef :pointer, type
      
      this.instance_exec(this,&b) if b
      
      return this
    end
    
    def struct name,type, *o
      const_set(name, st = Class.new(FFI::Struct))
      st.extend FFI::Helper::Struct
      st.type = type
      st.name = name
      st.namespace = self

      clib.typedef :pointer, type
           
      h = o.pop
      if h
        st.layout2(h)
      end
      
      return st
    end
  end
  
  def self.namespace n, libname, &b
    ::Object.const_set(n, mod = Module.new)
    mod.const_set(:Lib, Module.new)
    mod::Lib.extend FFI::Library
    mod.extend Namespace
    mod.instance_variable_set("@namespace", mod)
    mod::Lib.ffi_lib libname
    mod.instance_eval(&b)
  end
end
