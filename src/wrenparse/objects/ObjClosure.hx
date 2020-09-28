package wrenparse.objects;

import wrenparse.Utils.FixedArray;

/**
 * An instance of a first-class function and the environment it has closed over.
 * Unlike [ObjFn], this has captured the upvalues that the function accesses.
 */
class ObjClosure extends ObjFn {


    /**
     * The upvalues this function has closed over.
     */
    public var upValues:Array<ObjUpvalue>;

    
    public function new() {
        super();
        this.type = OBJ_CLOSURE;
    }
}


class CallFrame {
    /**
     * Instruction Pointer to the current (really next-to-be-executed) instruction in the
     * function's bytecode.
     */
    public var ip:Pointer<Int>;

    /**
     * The closure being executed.
     */
    public var closure:ObjClosure;

    /**
     * Pointer to the first stack slot used by this call frame. This will contain
     * the receiver, followed by the function's parameters, then local variables
     * and temporaries.
     */
    public var stackStart:Pointer<Value>;

    public function new() {}
}