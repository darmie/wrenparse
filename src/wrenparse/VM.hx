package wrenparse;

import wrenparse.objects.ObjFn;
import wrenparse.objects.ObjModule;
import wrenparse.objects.Obj;

import wrenparse.Compiler;


enum ErrorType 
{
  // A syntax or resolution error detected at compile time.
  WREN_ERROR_COMPILE;

  // The error message for a runtime error.
  WREN_ERROR_RUNTIME;

  // One entry of a runtime error's stack trace.
  WREN_ERROR_STACK_TRACE;
}


typedef VMConfig = {
    errorFn:(vm:VM, type:ErrorType, mpduleName:String, line:Int, message:String)->Void
}

class VM {

    public static var instance:VM;

    public var config:VMConfig;

    public var compiler:Compiler;

    public static function getInstance():VM {
        if(instance == null){
            return new VM();
        }

        return instance;
    }

    function new() {
        
    }


    public function pushRoot(obj:Obj) {
        
    }

    public function popRoot() {
        
    }

    public function defineVariable(module:ObjModule, start:Int, length:Int, value:Value, line:Int):Int {
        return 0;
    }

    public function functionBindName(fn:ObjFn, name:String) {
        
    }

    public function dumpCode(fn:ObjFn) {
        
    }
}