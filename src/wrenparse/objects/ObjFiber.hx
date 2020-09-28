package wrenparse.objects;

import wrenparse.objects.ObjClosure.CallFrame;


enum FiberState {
  // The fiber is being run from another fiber using a call to `try()`.
  FIBER_TRY;
  
  // The fiber was directly invoked by `runInterpreter()`. This means it's the
  // initial fiber used by a call to `wrenCall()` or `wrenInterpret()`.
  FIBER_ROOT;
  
  // The fiber is invoked some other way. If [caller] is `NULL` then the fiber
  // was invoked using `call()`. If [numFrames] is zero, then the fiber has
  // finished running and is done. If [numFrames] is one and that frame's `ip`
  // points to the first byte of code, the fiber has not been started yet.
  FIBER_OTHER;    
}

class ObjFiber extends Obj {
    /**
     * The stack of value slots. This is used for holding local variables and
     * temporaries while the fiber is executing. It is heap-allocated and grown
     * as needed.
     */
    public var stack:Pointer<Value>;

    /**
     * A pointer to one past the top-most value on the stack.
     */
    public var stackTop:Pointer<Value>;

    /**
     * The number of allocated slots in the stack array.
     */
    public var stackCapacity:Int;

    /**
     * The stack of call frames. This is a dynamic array that grows as needed but
     * never shrinks.
     */
    public var frames:Array<CallFrame>;
    /**
     * The number of frames currently in use in [frames].
     */
    public var numFrames:Int;
    /**
     * The number of [frames] allocated.
     */
    public var frameCapacity:Int;

    /**
     * Pointer to the first node in the linked list of open upvalues that are
     * pointing to values still on the stack. The head of the list will be the
     * upvalue closest to the top of the stack, and then the list works downwards.
     */
    public var openUpvalues:Pointer<ObjUpvalue>;

    /**
     * The fiber that ran this one. If this fiber is yielded, control will resume
     * to this one. May be `NULL`.
     */
    public var caller:Null<ObjFiber>;

    /**
     * If the fiber failed because of a runtime error, this will contain the
     * error object. Otherwise, it will be null.
     */
    public var error:Null<Value>;

    public var state:FiberState;

    public function new() {
        super();
        this.type = OBJ_FIBER;
    }
}