package wrenparse.objects;

import wrenparse.Pointer.DataPointer;
import wrenparse.Value.ValuePointer;
import wrenparse.Utils.FixedArray;
import wrenparse.VM;

/**
 * An instance of a first-class function and the environment it has closed over.
 * Unlike [ObjFn], this has captured the upvalues that the function accesses.
 */
class ObjClosure extends ObjFn {


    /**
     * The upvalues this function has closed over.
     */
    public var upValues:Array<ObjUpvalue>;

    
    public function new(vm:VM, module:ObjModule, maxSlots:Int) {
        this.type = OBJ_CLOSURE;
        this.upValues = [];
        super(vm, module, maxSlots);
    }

    public static function fromFn(vm:VM, fn:ObjFn){
        var closure:ObjClosure = new ObjClosure(vm, fn.module, fn.maxSlots);
        closure.constants = fn.constants;
        closure.code = fn.code;
        closure.debug = fn.debug;
        closure.arity = fn.arity;

        // ObjClosure* closure = ALLOCATE_FLEX(vm, ObjClosure,
        //     ObjUpvalue*, fn->numUpvalues);
        // initObj(vm, &closure->obj, OBJ_CLOSURE, vm->fnClass);

        // closure->fn = fn;

        // // Clear the upvalue array. We need to do this in case a GC is triggered
        // // after the closure is created but before the upvalue array is populated.
        for (i in 0...fn.numUpvalues) closure.upValues.remove(closure.upValues[i]);

        return closure;
    }
}


class CallFrame {
    /**
     * Instruction Pointer to the current (really next-to-be-executed) instruction in the
     * function's bytecode.
     */
    public var ip:DataPointer;

    /**
     * The closure being executed.
     */
    public var closure:ObjClosure;

    /**
     * Pointer to the first stack slot used by this call frame. This will contain
     * the receiver, followed by the function's parameters, then local variables
     * and temporaries.
     */
    public var stackStart:ValuePointer;

    public function new() {}
}