package wrenparse;

import wrenparse.Value.ValuePointer;
import wrenparse.Value.ValueBuffer;
import wrenparse.IO.Buffer;
import polygonal.ds.ArrayList;
import wrenparse.objects.*;
import wrenparse.Compiler;

enum ErrorType {
	// A syntax or resolution error detected at compile time.
	WREN_ERROR_COMPILE;

	// The error message for a runtime error.
	WREN_ERROR_RUNTIME;
	// One entry of a runtime error's stack trace.
	WREN_ERROR_STACK_TRACE;
}

enum WrenInterpretResult {
	WREN_RESULT_SUCCESS;
	WREN_RESULT_COMPILE_ERROR;
	WREN_RESULT_RUNTIME_ERROR;
}

typedef VMConfig = {
	errorFn:(vm:VM, type:ErrorType, mpduleName:String, line:Int, message:String) -> Void,
	reallocateFn:(vm:VM, gray:Array<Obj>, size:Int) -> Array<Obj>
}

class VM {
	public static var instance:VM;

	public var config:VMConfig;

	public var compiler:Compiler;

	public var numTempRoots:Int;

	public static var WREN_MAX_TEMP_ROOTS = 8;

	public var tempRoots:Array<Obj>;

	public var modules:ObjMap;

	public var apiStack:ValuePointer;

	public var fiber:ObjFiber;

	public var first:Obj;

	public var classClass:ObjClass;
	public var stringClass:ObjClass;
	public var numClass:ObjClass;
	public var nullClass:ObjClass;
	public var boolClass:ObjClass;
	public var rangeClass:ObjClass;
	public var fnClass:ObjClass;
	public var listClass:ObjClass;
	public var mapClass:ObjClass;

	public var grayCapacity:Int;
	public var grayCount:Int;
	public var gray:Array<Obj>;

	public var bytesAllocated:Int;

	public static var INITIAL_CALL_FRAMES = 4;

	public function new(config:VMConfig) {
		this.config = config;
	}

	public function interpret(moduleName:String, code:String):WrenInterpretResult {
		// var parser = new WrenParser(byte.ByteData.ofString(code), sourcePath);
		// this.compiler = Compiler.init(parser);
		var closure = compileSource(moduleName, code);
		if (closure == null)
			return WREN_RESULT_COMPILE_ERROR;
		pushRoot(closure);
		var fiber = new ObjFiber(this, closure);
		popRoot(); // fiber
		this.apiStack = null;

		return runInterpreter(fiber);
	}

	public function compileSource(moduleName:String, code:String, isExpression:Bool = false, printErrors:Bool = true):ObjClosure {
		var nameValue:Value = Value.NULL_VAL();
		if (moduleName != null) {
			nameValue = new ObjString(this, moduleName).OBJ_VAL();
			pushRoot(nameValue.as.obj);
		}

		var closure:ObjClosure = compileInModule(nameValue, code, isExpression, printErrors);

		if (moduleName != null)
			popRoot(); // nameValue.
		return closure;
	}

	public function getModule(name:Value):ObjModule {
		var moduleValue = modules.get(this, name);
		return !moduleValue.IS_UNDEFINED() ? cast moduleValue.as.obj : null;
	}

	public function compileInModule(name:Value, source:String, isExpression:Bool = false, printErrors:Bool = true) {
		// See if module has already been loaded
		var module = getModule(name);
		if (module == null) {
			module = new ObjModule(this, cast name.AS_OBJ());
			// It's possible for the wrenMapSet below to resize the modules map,
			// and trigger a GC while doing so. When this happens it will collect
			// the module we've just created. Once in the map it is safe.
			pushRoot(module);

			this.modules.set(this, name, module.OBJ_VAL());

			// Store it in the VM's module registry so we don't load the same module
			// multiple times.
			popRoot();
			// Implicitly import the core module.
			var coreModule:ObjModule = getModule(Value.NULL_VAL());
			for (i in 0...coreModule.variables.count) {
				coreModule.defineVariable(this, coreModule.variableNames.data[i].value[0], coreModule.variableNames.data[i].length,
					coreModule.variables.data[i], null);
			}
		}

		var fn = Compiler.compile(module, source, isExpression, printErrors);
		if (fn == null) {
			// TODO: Should we still store the module even if it didn't compile?
			return null;
		}

		pushRoot(fn);
		var closure = ObjClosure.fromFn(this, fn);
		popRoot(); // fn
		return closure;
	}

	public function pushRoot(obj:Obj) {
		Utils.ASSERT(obj != null, "Can't root NULL.");
		Utils.ASSERT(numTempRoots < WREN_MAX_TEMP_ROOTS, "Too many temporary roots.");

		tempRoots[numTempRoots++] = obj;
	}

	public function popRoot() {
		Utils.ASSERT(numTempRoots > 0, "No temporary roots to release.");

		numTempRoots--;
	}

	/**
	 * Returns the class of [value].
	 *
	 * @param value
	 */
	public inline function getClassInline(value:Value) {
		return switch value.type {
			case VAL_FALSE: this.boolClass;
			case VAL_NULL: this.nullClass;
			case VAL_NUM: this.numClass;
			case VAL_TRUE: this.boolClass;
			case VAL_UNDEFINED: throw ">unreachable>";
			case VAL_OBJ: value.as.obj.classObj;
		}
	}

	public function dumpCode(fn:ObjFn) {}

	public function reallocate(memory:Dynamic, oldSize:Int, newSize:Int) {}

	public function grayObj(obj:Obj) {
		if (obj == null)
			return;

		// Stop if the object is already darkened so we don't get stuck in a cycle.
		if (obj.isDark)
			return;

		// It's been reached.
		obj.isDark = true;

		// Add it to the gray list so it can be recursively explored for
		// more marks later.
		if (this.grayCount >= this.grayCapacity) {
			this.grayCapacity = this.grayCount * 2;
			#if cpp
			this.gray = this.config.reallocateFn(this, this.gray, this.grayCapacity * cpp.sizeof(Obj));
			#else
			this.gray = this.config.reallocateFn(this, this.gray, this.grayCapacity * 256);
			#end
		}

		this.gray[this.grayCount++] = obj;
	}

	public function grayValue(value:Value) {
		if (!value.IS_OBJ())
			return;
		this.grayObj(value.as.obj);
	}

	public function grayBuffer(buffer:ValueBuffer) {
		for (i in 0...buffer.count) {
			this.grayValue(buffer.data[i]);
		}
	}

	public function blackenClass(classObj:ObjClass) {
		// The metaclass.
		grayObj(classObj.classObj);

		// The superclass.
		grayObj(classObj.superClass);
		// Method function objects.
		for (i in 0...classObj.methods.count) {
			if (classObj.methods.data[i].type == METHOD_BLOCK) {
				grayObj(classObj.methods.data[i].as.closure);
			}
		}

		grayObj(classObj.name);
		// Keep track of how much memory is still in use.
		#if cpp
		this.bytesAllocated += cpp.sizeof(ObjClass);
		this.bytesAllocated += classObj.methods.capacity * cpp.sizeof(Method);
		#else
		this.bytesAllocated += 256;
		this.bytesAllocated += classObj.methods.capacity * 256;
		#end
	}

	public function blackenClosure(closure:ObjClosure) {
		grayObj(closure);
		// Method function objects.
		for (i in 0...closure.numUpvalues) {
			grayObj(closure.upValues[i]);
		}

		// Keep track of how much memory is still in use.
		#if cpp
		this.bytesAllocated += cpp.sizeof(ObjClosure);
		this.bytesAllocated += cpp.sizeof(ObjUpvalue) * closure.numUpvalues;
		#else
		this.bytesAllocated += 256;
		this.bytesAllocated += closure.numUpvalues * 256;
		#end
	}

	public function blackenFiber(fiber:ObjFiber) {
		// Stack functions.
		for (i in 0...fiber.numFrames) {
			grayObj(fiber.frames[i].closure);
		}

		// Stack variables.
		var slot:ValuePointer = fiber.stack;
		while (slot.lt(fiber.stackTop)) {
			grayValue(slot.value());
			slot.inc();
		}
		var upvalue = fiber.openUpvalues;
		while (upvalue != null) {
			grayObj(upvalue.value());
			upvalue.setValue(0, cast upvalue.value().next);
		}
		// The caller.
		grayObj(fiber.caller);
		grayValue(fiber.error);

		// Keep track of how much memory is still in use.
		#if cpp
		this.bytesAllocated += cpp.sizeof(ObjFiber);
		this.bytesAllocated += cpp.sizeof(ObjFiber) * fiber.frameCapacity;
		this.bytesAllocated += cpp.sizeof(Value) * fiber.stackCapacity;
		#else
		this.bytesAllocated += 256;
		this.bytesAllocated += 256 * fiber.frameCapacity;
		this.bytesAllocated += 256 * fiber.stackCapacity;
		#end
	}

	public function ensureSlot(numSlots:Int) {
		// If we don't have a fiber accessible, create one for the API to use.
		if (apiStack == null) {
			fiber = new ObjFiber(this, null);
			apiStack = fiber.stack;
		}

		var currentSize = fiber.stackTop.sub(apiStack);
		if (currentSize >= numSlots)
			return;

		// Grow the stack if needed.
		var needed = apiStack.sub(fiber.stack) + numSlots;
		ensureStack(fiber, needed);

		fiber.stackTop.setValue(0, apiStack.value(numSlots));
	}

	public function getSlotCount(){
		if(apiStack == null) return 0;

		return fiber.stackTop.sub(apiStack);
	}

	public function ensureStack(fiber:ObjFiber, needed:Int){
		if (fiber.stackCapacity >= needed) return;

		var capacity = Utils.wrenPowerOf2Ceil(needed);
		var oldStack = fiber.stack;
		fiber.stack = new ValuePointer(new ArrayList(capacity, fiber.stack.arr.toArray()));
		fiber.stackCapacity = capacity;

	}

	public function runInterpreter(fiber:ObjFiber):WrenInterpretResult {
		// Remember the current fiber so we can find it if a GC happens.
		this.fiber = fiber;

		this.fiber.state = FIBER_ROOT;

		var frame:ObjClosure.CallFrame = null;

		var stackStart:Pointer<Value> = null;
		var ip:Pointer<Int> = null;
		var fn:ObjFn = null;

		function PUSH(value:Value) {
			fiber.stackTop.setValue(0, value);
		}
		function POP() {
			fiber.stackTop.dec();
			return fiber.stackTop.pointer(0);
		}
		function DROP() {
			fiber.stackTop.drop();
		}
		function PEEK() {
			return fiber.stackTop.pointer(-1);
		}
		function PEEK2() {
			return fiber.stackTop.pointer(-2);
		}
		function READ_BYTE() {
			ip.inc();
			return ip.pointer(0);
		}

		function READ_SHORT() {
			ip.inc();
			ip.inc();
			return (ip.value(-2) << 8) | ip.value(-1);
		}
		// Use this before a CallFrame is pushed to store the local variables back
		// into the current one.
		function STORE_FRAME() {
			frame.ip = ip;
		}

		function LOAD_FRAME() {
			do {
				frame = fiber.frames[fiber.numFrames - 1];
				stackStart = frame.stackStart;
				ip = frame.ip;
				fn = cast frame.closure;
			} while (false);
		}

		return null;
	}
}
