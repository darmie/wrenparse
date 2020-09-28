package wrenparse.objects;

import wrenparse.IO.Buffer;
import wrenparse.objects.ObjClosure;
import wrenparse.Value.Primitive;


enum MethodType {
  // A primitive method implemented in C in the VM. Unlike foreign methods,
  // this can directly manipulate the fiber's stack.
  METHOD_PRIMITIVE;

  // A primitive that handles .call on Fn.
  METHOD_FUNCTION_CALL;

  // A externally-defined Haxe method.
  METHOD_FOREIGN;

  // A normal user-defined method.
  METHOD_BLOCK;
  
  // No method for the given symbol.
  METHOD_NONE;
}

typedef MethodAs = {
    ?primitive:Primitive,
    ?foreign:Dynamic, // WrenForeignMethodFn
    ?closure:ObjClosure
}

class Method {
    public var type:MethodType;
    public var as:MethodAs;

    public function new(type:MethodType) {
        
    }
}

typedef MethodBuffer = Buffer<Method>;


class ObjClass extends Obj {

    public var objClass:ObjClass;
    /**
     * The number of fields needed for an instance of this class, including all
     * of its superclass fields.
     */
    public var numFields:Int;

    /**
     * The table of methods that are defined in or inherited by this class.
     * Methods are called by symbol, and the symbol directly maps to an index in
     * this table. This makes method calls fast at the expense of empty cells in
     * the list for methods the class doesn't support.
     * 
     * You can think of it as a hash table that never has collisions but has a
     * really low load factor. Since methods are pretty small (just a type and a
     * pointer), this should be a worthwhile trade-off.
     */
    public var methods:MethodBuffer;

    /**
     * The name of the class
     */
    public var name:ObjString;


    public function new() {
        super();
        this.type = OBJ_CLASS;
    }
}