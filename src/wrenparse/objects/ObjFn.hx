package wrenparse.objects;

import wrenparse.IO.IntBuffer;
import wrenparse.Value.ValueBuffer;
import wrenparse.IO.ByteBuffer;

/**
 * A function object. It wraps and owns the bytecode and other debug information
 * for a callable chunk of code.
 *
 * Function objects are not passed around and invoked directly. Instead, they
 * are always referenced by an [ObjClosure] which is the real first-class
 * representation of a function. This isn't strictly necessary if the function
 * has no upvalues, but lets the rest of the VM assume all called objects will
 * be closures.
 */
class ObjFn extends Obj {
    public var code:ByteBuffer;
    public var constants:ValueBuffer;
    /**
     * The module where this function was defined.
     */
    public var module:ObjModule;

    /**
     * The maximum number of stack slots this function may use.
     */
    public var maxSlots:Int;

    /**
     * The number of upvalues this function closes over.
     */
    public var numUpvalues:Int;

    /**
     * The number of parameters this function expects. Used to ensure that .call
     * handles a mismatch between number of parameters and arguments. This will
     * only be set for fns, and not ObjFns that represent methods or scripts.
     */
    public var arity:Int;

    public var debug:FnDebug;

    public function new(module:ObjModule, numLocals:Int) {
        super();
        this.type = OBJ_FN;
    }
}

/**
 * Stores debugging information for a function used for things like stack
 * traces.
 */
class FnDebug {
    /**
     * The name of the function. Heap allocated and owned by the FnDebug.
     */
    public var name:String;
    /**
     * An array of line numbers. There is one element in this array for each
     * bytecode in the function's bytecode array. The value of that element is
     * the line in the source code that generated that instruction.
     */
    public var sourceLines:IntBuffer;

    public function new(name:String, sourceLines:IntBuffer) {
        this.name= name; 
        this.sourceLines = sourceLines;
    }
}