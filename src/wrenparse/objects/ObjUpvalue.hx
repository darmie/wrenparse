package wrenparse.objects;

import polygonal.ds.ArrayList;
import wrenparse.Value.ValuePointer;
import haxe.ds.Vector;
import wrenparse.Compiler.MAX_UPVALUES;

/**
 * The dynamically allocated data structure for a variable that has been used
 * by a closure. Whenever a function accesses a variable declared in an
 * enclosing function, it will get to it through this.
 *
 * An upvalue can be either "closed" or "open". An open upvalue points directly
 * to a [Value] that is still stored on the fiber's stack because the local
 * variable is still in scope in the function where it's declared.
 *
 * When that local variable goes out of scope, the upvalue pointing to it will
 * be closed. When that happens, the value gets copied off the stack into the
 * upvalue itself. That way, it can have a longer lifetime than the stack
 * variable.
 * */
class ObjUpvalue extends Obj {

    /**
     * Pointer to the variable this upvalue is referencing.
     */
    public var value:ValuePointer;
    /**
     * If the upvalue is closed (i.e. the local variable it was pointing to has
     * been popped off the stack) then the closed-over value will be hoisted out
     * of the stack into here. [value] will then be changed to point to this.
     */
    public var closed:Value;

    public function new(vm:VM, value:Value) {
        this.type = OBJ_UPVALUE;
        this.closed = Value.NULL_VAL();
        this.value = new ValuePointer(new ArrayList(MAX_UPVALUES));
        this.next = null;
        super(vm, OBJ_UPVALUE, null);
    }
}