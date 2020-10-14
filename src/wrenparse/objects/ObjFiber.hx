package wrenparse.objects;

import wrenparse.Value;
import wrenparse.Value.ValuePointer;
import wrenparse.objects.ObjClosure.CallFrame;
import wrenparse.VM.INITIAL_CALL_FRAMES;
import wrenparse.Utils;
import haxe.ds.Vector;

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
	public var stack:ValuePointer;

	/**
	 * A pointer to one past the top-most value on the stack.
	 */
	public var stackTop:ValuePointer;

	/**
	 * The number of allocated slots in the stack array.
	 */
	public var stackCapacity:Int;

	/**
	 * The stack of call frames. This is a dynamic array that grows as needed but
	 * never shrinks.
	 */
	public var frames:Vector<CallFrame>;

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

	public function new(vm:VM, closure:ObjClosure) {
		// Add one slot for the unused implicit receiver slot that the compiler
		// assumes all functions have.
		var stackCapacity = closure == null ? 1 : Utils.wrenPowerOf2Ceil(closure.maxSlots + 1);
		var stack:ValuePointer = new ValuePointer(new polygonal.ds.ArrayList(stackCapacity));

		// ObjFiber* fiber = ALLOCATE(vm, ObjFiber);
		// initObj(vm, &fiber->obj, OBJ_FIBER, vm->fiberClass);

		this.stack = stack;
		this.stackTop = this.stack;
		this.stackCapacity = stackCapacity;

		this.frames = new haxe.ds.Vector(INITIAL_CALL_FRAMES);
		this.frameCapacity = INITIAL_CALL_FRAMES;
		this.numFrames = 0;

		this.openUpvalues = null;
		this.caller = null;
		this.error = Value.NULL_VAL();
		this.state = FIBER_OTHER;
		this.type = OBJ_FIBER;

		if (closure != null) {
			// Initialize the first call frame.
			// wrenAppendCallFrame(vm, fiber, closure, fiber->stack);

			// The first slot always holds the closure.
			this.stackTop.setValue(0, closure.OBJ_VAL());
			this.stackTop.inc();
		}

		super(vm, OBJ_FIBER, null);
	}

	public function hasError():Bool {
		return !fiber.error.IS_NULL();
	}

	public function callFunction(vm:VM, closure:ObjClosure, numArgs:Int) {}

	public function closeUpvalues(value:ValuePointer) {}

	public function captureUpvalues(vm:VM, upvalues:ValuePointer):ObjUpvalue {
		return null;
	}

	public function callForeign(vm:VM, foreign:VM.WrenForeignMethodFn, numArgs:Int) {
		Utils.ASSERT(vm.apiStack == null, "Cannot already be in foreign call.");
		vm.apiStack = fiber.stackTop.pointer(-numArgs);
		foreign(vm);
		// Discard the stack slots for the arguments and temporaries but leave one
		// for the result.
		fiber.stackTop = vm.apiStack.pointer(1);

		vm.apiStack = null;
	}

	public function createForeign(vm:VM, stack:ValuePointer) {
		var classObj = stack.value().AS_CLASS();
		Utils.ASSERT(classObj.numFields == -1, "Class must be a foreign class.");
		// TODO: Don't look up every time.
		var symbol = vm.methodNames.find("<allocate>");
		Utils.ASSERT(symbol != -1, "Should have defined <allocate> symbol.");

		Utils.ASSERT(classObj.methods.count > symbol, "Class should have allocator.");
		var method = classObj.methods.data[symbol];

		Utils.ASSERT(method.type == METHOD_FOREIGN, "Allocator should be foreign.");

		// Pass the constructor arguments to the allocator as well.
		ASSERT(vm.apiStack == null, "Cannot already be in foreign call.");
		vm.apiStack = stack;

		method.as.foreign(vm);

		vm.apiStack = null;
	}
}
