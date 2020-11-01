package wrenparse.objects;

import haxe.io.UInt16Array;
import wrenparse.Pointer.DataPointer;
import polygonal.ds.ArrayList;
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
		for(i in 0...INITIAL_CALL_FRAMES){
			this.frames.set(i, new CallFrame());
		}
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
			this.appendCallFrame(vm, closure, this.stack);

			// The first slot always holds the closure.
			this.stackTop.setValue(0, closure.OBJ_VAL());
			this.stackTop.inc();
		}

		super(vm, OBJ_FIBER, null);
	}

	public function hasError():Bool {
		return !error.IS_NULL();
	}

	public function callFunction(vm:VM, closure:ObjClosure, numArgs:Int) {
		// Grow the call frame array if needed.
		if (numFrames + 1 > frameCapacity) {
			var max = frameCapacity * 2;
			var old = frames;
			frames = new Vector(frameCapacity); // (CallFrame*)wrenReallocate(vm, fiber->frames, sizeof(CallFrame) * fiber->frameCapacity, sizeof(CallFrame) * max);
			for(i in 0...frames.length){
				frames.set(i, old[i]);
			}
			frameCapacity = max;
		}
		// Grow the stack if needed.
		
		var stackSize = (stackTop.sub(stack));
	
		var needed = stackSize + closure.maxSlots;

		ensureStack(vm, needed);
		appendCallFrame(vm, closure, stackTop.pointer(vm.stackOffset-numArgs));
	}

	public function ensureStack(vm:VM, needed:Int) {
		if (stackCapacity >= needed)
			return;

		var capacity = Utils.wrenPowerOf2Ceil(needed);
		var oldStack = stack;
		stack = new ValuePointer(oldStack.arr);
		stackCapacity = capacity;

		// If the reallocation moves the stack, then we need to recalculate every
		// pointer that points into the old stack to into the same relative distance
		// in the new stack. We have to be a little careful about how these are
		// calculated because pointer subtraction is only well-defined within a
		// single array, hence the slightly redundant-looking arithmetic below.

		// if (stack.arr != oldStack.arr) {
		// 	// Top of the stack.
		// 	if (vm.apiStack.gte(oldStack) && vm.apiStack.lte(this.stackTop)) {
		// 		vm.apiStack = this.stack.pointer(vm.apiStack.sub(oldStack));
		// 	}
		// 	// Stack pointer for each call frame.
		// 	for (i in 0...this.numFrames) {
		// 		var frame:CallFrame = this.frames[i];
		// 		frame.stackStart = this.stack.pointer(frame.stackStart.sub(oldStack));
		// 	}
		// 	var upvalue = openUpvalues.value();
		// 	while (upvalue != null) {
		// 		upvalue.value = this.stack.pointer(upvalue.value.sub(oldStack));
		// 		upvalue = cast upvalue.next;
		// 	}
		// 	this.stackTop = this.stack.pointer(this.stackTop.sub(oldStack));
		// }
	}

	public function appendCallFrame(vm:VM, closure:ObjClosure, stackStart:ValuePointer) {
		// The caller should have ensured we already have enough capacity.
		Utils.ASSERT(frameCapacity > numFrames, "No memory for call frame.");
		var frame = frames[numFrames++];
		frame.stackStart = stackStart;
		frame.closure = closure;
		frame.ip = closure.code.data;
	}

	public function closeUpvalues(last:ValuePointer) {
		while (openUpvalues != null && openUpvalues.value().value.gte(last)) {
			var upvalue = openUpvalues.value();

			// Move the value into the upvalue itself and point the upvalue to it.
			upvalue.closed = upvalue.value.value();
			upvalue.value.setValue(0, upvalue.closed);

			// Remove it from the open upvalue list.
			openUpvalues.setValue(0, cast upvalue.next);
		}
	}

	/**
	 * Captures the local variable [local] into an [Upvalue]. If that local is
	 * already in an upvalue, the existing one will be used. (This is important to
	 * ensure that multiple closures closing over the same variable actually see
	 * the same variable.) Otherwise, it will create a new open upvalue and add it
	 * the fiber's list of upvalues.
	 * @param vm
	 * @param upvalues
	 * @return ObjUpvalue
	 */
	public function captureUpvalues(vm:VM, local:ValuePointer):ObjUpvalue {
		// If there are no open upvalues at all, we must need a new one.
		if (openUpvalues == null) {
			openUpvalues.setValue(0, new ObjUpvalue(vm, local.value()));
			return openUpvalues.value();
		}
		var prevUpvalue:Pointer<ObjUpvalue> = null;
		var upvalue = openUpvalues;

		// Walk towards the bottom of the stack until we find a previously existing
		// upvalue or pass where it should be.
		while (upvalue != null && upvalue.value().value.gt(local)) {
			prevUpvalue = upvalue;
			upvalue.setValue(0, cast upvalue.value().next);
		}
		// Found an existing upvalue for this local.
		if (upvalue != null && upvalue.value().value == local)
			return upvalue.value();
		// We've walked past this local on the stack, so there must not be an
		// upvalue for it already. Make a new one and link it in in the right
		// place to keep the list sorted.
		var createdUpvalue = new ObjUpvalue(vm, local.value());
		if (prevUpvalue == null) {
			// The new one is the first one in the list.
			openUpvalues.setValue(0, createdUpvalue);
		} else {
			prevUpvalue.value().next = createdUpvalue;
		}
		createdUpvalue.next = upvalue.value();
		return createdUpvalue;
	}

	public function callForeign(vm:VM, foreign:VM.WrenForeignMethodFn, numArgs:Int) {
		Utils.ASSERT(vm.apiStack == null, "Cannot already be in foreign call.");
		vm.apiStack = stackTop.pointer(-numArgs);
		foreign(vm);
		// Discard the stack slots for the arguments and temporaries but leave one
		// for the result.
		stackTop = vm.apiStack.pointer(1);

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
		Utils.ASSERT(vm.apiStack == null, "Cannot already be in foreign call.");
		vm.apiStack = stack;

		method.as.foreign(vm);

		vm.apiStack = null;
	}
}
