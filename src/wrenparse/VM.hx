package wrenparse;

import wrenparse.objects.ObjClass.Method;
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

	public function getSlotCount() {
		if (apiStack == null)
			return 0;

		return fiber.stackTop.sub(apiStack);
	}

	public function ensureStack(fiber:ObjFiber, needed:Int) {
		if (fiber.stackCapacity >= needed)
			return;

		var capacity = Utils.wrenPowerOf2Ceil(needed);
		var oldStack = fiber.stack;
		fiber.stack = new ValuePointer(new ArrayList(capacity, fiber.stack.arr.toArray()));
		fiber.stackCapacity = capacity;
	}

	public function checkArity(args:ValuePointer, numArgs:Int):Bool {
		return false;
	}

	public function runtimeError() {}

	public function callForeign(fiber:ObjFiber, foreign:ObjForeign, numArgs:Int) {}

	public function createForeign(fiber:ObjFiber, vals:ValuePointer) {}

	public function createClass(numFields:Int, module:ObjModule){}

	public function functionBindName(fn:ObjFn, name:String) {}

	public function bindMethod(methodType:Int, symbol:Int, module:ObjModule, classObj:ObjClass, methodValue:Value){}

	public function importModule(value:Value):Value {
		return null;
	}

	public function runInterpreter(fiber:ObjFiber):WrenInterpretResult {
		// Remember the current fiber so we can find it if a GC happens.
		this.fiber = fiber;

		this.fiber.state = FIBER_ROOT;

		var frame:ObjClosure.CallFrame = null;

		var stackStart:ValuePointer = null;
		var ip:Pointer<Int> = null;
		var fn:ObjFn = null;

		function PUSH(value:Value) {
			fiber.stackTop.inc();
			fiber.stackTop.setValue(0, value);
		}
		function POP() {
			return fiber.stackTop.dec();
		}
		function DROP() {
			return fiber.stackTop.drop();
		}
		function PEEK() {
			return fiber.stackTop.value(-1);
		}
		function PEEK2() {
			return fiber.stackTop.value(-2);
		}
		function READ_BYTE() {
			return ip.value(1);
		}

		function READ_SHORT() {
			ip.inc();
			ip.setValue(0, 2);
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

		LOAD_FRAME();

		var instruction:Code;
		while (true) {
			function completeCall(numArgs:Int, symbol:Int, args:ValuePointer, classObj:ObjClass) {
				var method:Method = null;
				// If the class's method table doesn't include the symbol, bail.
				if (symbol >= classObj.methods.count || (method = classObj.methods.data[symbol]).type == METHOD_NONE) {
					classObj.methodNotFound(this, symbol);
					// RUNTIME_ERROR
					do {
						STORE_FRAME();
						runtimeError();
						if (fiber == null)
							return WREN_RESULT_RUNTIME_ERROR;
						fiber = this.fiber;
						LOAD_FRAME();
					} while (false);
				}

				return switch method.type {
					case METHOD_PRIMITIVE:
						{
							if (method.as.primitive(this, args)) {
								// The result is now in the first arg slot. Discard the other
								// stack slots.
								// fiber->stackTop -= numArgs - 1;
								fiber.stackTop = fiber.stackTop.pointer(-(numArgs - 1));
							} else {
								// An error, fiber switch, or call frame change occurred.
								STORE_FRAME();

								// If we don't have a fiber to switch to, stop interpreting.
								fiber = this.fiber;
								if (fiber == null)
									return WREN_RESULT_SUCCESS;
								if (fiber.hasError())
									// RUNTIME_ERROR
									do {
										STORE_FRAME();
										runtimeError();
										if (fiber == null)
											return WREN_RESULT_RUNTIME_ERROR;
										fiber = this.fiber;
										LOAD_FRAME();
									} while (false);
								LOAD_FRAME();
							}
							return null;
						}
					case METHOD_FUNCTION_CALL:
						{
							if (!this.checkArity(args, numArgs)) {
								// RUNTIME_ERROR
								do {
									STORE_FRAME();
									runtimeError();
									if (fiber == null)
										return WREN_RESULT_RUNTIME_ERROR;
									fiber = this.fiber;
									LOAD_FRAME();
								} while (false);
							}
							STORE_FRAME();
							method.as.primitive(this, args);
							LOAD_FRAME();
							return null;
						}
					case METHOD_FOREIGN: {
							callForeign(fiber, method.as.foreign, numArgs);
							if (fiber.hasError())
								// RUNTIME_ERROR
								do {
									STORE_FRAME();
									runtimeError();
									if (fiber == null)
										return WREN_RESULT_RUNTIME_ERROR;
									fiber = this.fiber;
									LOAD_FRAME();
								} while (false);
							return null;
						}
					case METHOD_BLOCK: {
							STORE_FRAME();
							fiber.callFunction(this, method.as.closure, numArgs);
							LOAD_FRAME();
							return null;
						}
					case METHOD_NONE: {
							Utils.UNREACHABLE();
							return null;
						}
				}
			}

			switch (instruction = READ_BYTE()) {
				case CODE_LOAD_LOCAL_0 | CODE_LOAD_LOCAL_1 | CODE_LOAD_LOCAL_3 | CODE_LOAD_LOCAL_4 | CODE_LOAD_LOCAL_5 | CODE_LOAD_LOCAL_6 |
					CODE_LOAD_LOCAL_7 | CODE_LOAD_LOCAL_8:
					{
						PUSH(stackStart.value(instruction - CODE_LOAD_LOCAL_0));
						continue;
					}
				case CODE_LOAD_LOCAL:
					{
						PUSH(stackStart.value(READ_BYTE()));
						continue;
					}
				case CODE_LOAD_FIELD_THIS:
					{
						var field = READ_BYTE();
						var receiver = stackStart.value(0);
						Utils.ASSERT(receiver.IS_INSTANCE(), "Receiver should be instance.");
						var instance = receiver.AS_INSTANCE();
						Utils.ASSERT(field < instance.classObj.numFields, "Out of bounds field.");
						PUSH(instance.fields[field]);
						continue;
					}
				case CODE_POP:
					{
						DROP();
						continue;
					}
				case CODE_CALL_0 | CODE_CALL_1 | CODE_CALL_2 | CODE_CALL_3 | CODE_CALL_4 | CODE_CALL_5 | CODE_CALL_6 | CODE_CALL_7 | CODE_CALL_8 |
					CODE_CALL_9 | CODE_CALL_10 | CODE_CALL_11 | CODE_CALL_12 | CODE_CALL_13 | CODE_CALL_14 | CODE_CALL_15 | CODE_CALL_16:
					{
						// Add one for the implicit receiver argument.
						var numArgs = instruction - CODE_CALL_0 + 1
							; // numArgs
						var symbol = READ_SHORT(); // symbol
						// The receiver is the first argument.
						var args = fiber.stackTop.pointer(-numArgs);
						var classObj = getClassInline(args.value(0));
						var res = completeCall(numArgs, symbol, args, classObj);
						if (res == null) {
							continue;
						} else {
							return res;
						}
					}
				case CODE_SUPER_0 | CODE_SUPER_1 | CODE_SUPER_2 | CODE_SUPER_3 | CODE_SUPER_4 | CODE_SUPER_5 | CODE_SUPER_6 | CODE_SUPER_7 | CODE_SUPER_8 |
					CODE_SUPER_9 | CODE_SUPER_10 | CODE_SUPER_11 | CODE_SUPER_12 | CODE_SUPER_13 | CODE_SUPER_14 | CODE_SUPER_15 | CODE_SUPER_16:
					{
						// Add one for the implicit receiver argument.
						var numArgs = instruction - CODE_SUPER_0 + 1
							; // numArgs
						var symbol = READ_SHORT(); // symbol
						// The receiver is the first argument.
						var args = fiber.stackTop.pointer(-numArgs);
						// The superclass is stored in a constant.
						var classObj = fn.constants.data[READ_SHORT()].AS_CLASS();
						var res = completeCall(numArgs, symbol, args, classObj);
						if (res == null) {
							continue;
						} else {
							return res;
						}
					}
				case CODE_LOAD_UPVALUE:
					{
						var upvalues = frame.closure.upValues;
						PUSH(upvalues[READ_BYTE()].value.value());
						continue;
					}
				case CODE_STORE_UPVALUE:
					{
						var upvalues = frame.closure.upValues;
						upvalues[READ_BYTE()].value.setValue(0, PEEK());
						continue;
					}
				case CODE_LOAD_MODULE_VAR:
					{
						PUSH(fn.module.variables.data[READ_SHORT()]);
						continue;
					}
				case CODE_STORE_MODULE_VAR:
					{
						fn.module.variables.data[READ_SHORT()] = PEEK();
						continue;
					}
				case CODE_STORE_FIELD_THIS:
					{
						var field = READ_BYTE();
						var receiver = stackStart.value();
						Utils.ASSERT(receiver.IS_INSTANCE(), "Receiver should be instance.");
						var instance = receiver.AS_INSTANCE();
						Utils.ASSERT(field < instance.classObj.numFields, "Out of bounds field.");
						instance.fields[field] = PEEK();
						continue;
					}
				case CODE_LOAD_FIELD:
					{
						var field = READ_BYTE();
						var receiver = POP();
						Utils.ASSERT(receiver.IS_INSTANCE(), "Receiver should be instance.");
						var instance = receiver.AS_INSTANCE();
						Utils.ASSERT(field < instance.classObj.numFields, "Out of bounds field.");
						PUSH(instance.fields[field]);
						continue;
					}
				case CODE_STORE_FIELD:
					{
						var field = READ_BYTE();
						var receiver = POP();
						Utils.ASSERT(receiver.IS_INSTANCE(), "Receiver should be instance.");
						var instance = receiver.AS_INSTANCE();
						Utils.ASSERT(field < instance.classObj.numFields, "Out of bounds field.");
						instance.fields[field] = PEEK();
						continue;
					}
				case CODE_JUMP:
					{
						var offset = READ_SHORT();
						ip.inc();
						ip.setValue(0, offset);
						continue;
					}
				case CODE_LOOP:
					{
						// Jump back to the top of the loop.
						var offset = READ_SHORT();
						ip.setValue(-1, offset);
						continue;
					}
				case CODE_JUMP_IF:
					{
						var offset = READ_SHORT();
						var condition = POP();
						if (condition.IS_FALSE() || condition.IS_NULL())
							ip.inc();
						ip.setValue(0, offset);
						continue;
					}
				case CODE_AND:
					{
						var offset = READ_SHORT();
						var condition = PEEK();
						if (condition.IS_FALSE() || condition.IS_NULL()) {
							// Short-circuit the right hand side.
							ip.inc();
							ip.setValue(0, offset);
						} else {
							// Discard the condition and evaluate the right hand side.
							DROP();
						}

						continue;
					}
				case CODE_OR:
					{
						var offset = READ_SHORT();
						var condition = PEEK();
						if (condition.IS_FALSE() || condition.IS_NULL()) {
							// Discard the condition and evaluate the right hand side.
							DROP();
						} else {
							// Short-circuit the right hand side.
							ip.inc();
							ip.setValue(0, offset);
						}
						continue;
					}
				case CODE_CLOSE_UPVALUE:
					{
						// Close the upvalue for the local if we have one.
						fiber.closeUpvalues(fiber.stackTop.pointer(-1));
						DROP();
						continue;
					}
				case CODE_RETURN:
					{
						var result = POP();
						fiber.numFrames--;
						// Close any upvalues still in scope.
						fiber.closeUpvalues(fiber.stackStart);
						// If the fiber is complete, end it.
						if (fiber.numFrames == 0) {
							// See if there's another fiber to return to. If not, we're done.
							if (fiber.caller == null) {
								// Store the final result value at the beginning of the stack so the
								// Haxe API can get it.
								fiber.stack.setValue(0, result);
								fiber.stackTop = fiber.stack.pointer(1);
								return WREN_RESULT_SUCCESS;
							}

							var resumingFiber = fiber.caller;
							fiber.caller = null;
							fiber = resumingFiber;
							this.fiber = resumingFiber;

							// Store the result in the resuming fiber.
							fiber.stackTop.setValue(-1, result);
						} else {
							// Store the result of the block in the first slot, which is where the
							// caller expects it.
							stackStart.setValue(0, result);

							// Discard the stack slots for the call frame (leaving one slot for the
							// result).
							fiber.stackTop = frame.stackStart.pointer(1);
						}
						LOAD_FRAME();
						continue;
					}
				case CODE_CONSTRUCT:
					{
						Utils.ASSERT(stackStart.value().IS_CLASS(), "'this' should be a class.");
						stackStart.setValue(0, stackStart.value().AS_CLASS().newInstance());
						continue;
					}
				case CODE_FOREIGN_CONSTRUCT:
					{
						Utils.ASSERT(stackStart.value().IS_CLASS(), "'this' should be a class.");
						createForeign(fiber, stackStart);
					}
				case CODE_CLOSURE:
					{
						// Create the closure and push it on the stack before creating upvalues
						// so that it doesn't get collected.
						var func = fn.constants.data[READ_SHORT()].AS_FUN();
						var closure = new ObjClosure(vm, func);
						PUSH(closure.OBJ_VAL());
						// Capture upvalues, if any.
						for(i in 0...func.numUpvalues){
							var isLocal = READ_BYTE();
							var index = READ_BYTE();
							if(isLocal != null){
								// Make an new upvalue to close over the parent's local variable.
								closure.upValues[i] = fiber.captureUpvalue(this, frame.stackStart.pointer(index));
							} else {
								// Use the same upvalue as the current call frame.
								closure.upValues[i] = frame.closure.upValues[index];
							}
						}
						continue;
					}
				case CODE_CLASS:{
					createClass(READ_BYTE(), null);
					if(fiber.hasError()) {
						// RUNTIME_ERROR
						do {
							STORE_FRAME();
							runtimeError();
							if (fiber == null)
								return WREN_RESULT_RUNTIME_ERROR;
							fiber = this.fiber;
							LOAD_FRAME();
						} while (false);
					}
					continue;
				}
				case CODE_FOREIGN_CLASS:{
					createClass(-1, fn.module);
					if(fiber.hasError()) {
						// RUNTIME_ERROR
						do {
							STORE_FRAME();
							runtimeError();
							if (fiber == null)
								return WREN_RESULT_RUNTIME_ERROR;
							fiber = this.fiber;
							LOAD_FRAME();
						} while (false);
					}
					continue;
				}
				case CODE_METHOD_INSTANCE | CODE_METHOD_STATIC:{
					var symbol = READ_SHORT();
					var classObj = PEEK().AS_CLASS();
					var method = PEEK2();
					bindMethod(instruction, symbol, fn.module, classObj, method);
					if(fiber.hasError()) {
						// RUNTIME_ERROR
						do {
							STORE_FRAME();
							runtimeError();
							if (fiber == null)
								return WREN_RESULT_RUNTIME_ERROR;
							fiber = this.fiber;
							LOAD_FRAME();
						} while (false);
					}
					DROP();
      				DROP();
					continue;
				}
				case CODE_END_MODULE:{
					lastModule = fn.module;
					PUSH(Value.NULL_VAL());
					continue;
				}
				case CODE_IMPORT_MODULE:{
					// Make a slot on the stack for the module's fiber to place the return
					// value. It will be popped after this fiber is resumed. Store the
					// imported module's closure in the slot in case a GC happens when
					// invoking the closure.	
					PUSH(importModule(fn.constants.data[READ_SHORT()]));
					if(fiber.hasError()) {
						// RUNTIME_ERROR
						do {
							STORE_FRAME();
							runtimeError();
							if (fiber == null)
								return WREN_RESULT_RUNTIME_ERROR;
							fiber = this.fiber;
							LOAD_FRAME();
						} while (false);
					}
					// If we get a closure, call it to execute the module body.
					if(PEEK().IS_CLOSURE()){
						STORE_FRAME();
						var closure = PEEK().AS_CLOSURE();
						fiber.callFunction(closure, 1);
						LOAD_FRAME();
					} else {
						// The module has already been loaded. Remember it so we can import
						// variables from it if needed.
						lastModule = PEEK().AS_MODULE();
					}
					continue;
				}
				case CODE_IMPORT_VARIABLE: {
					var variable = fn.constants.data[READ_SHORT()];
					Utils.ASSERT(lastModule != null, "Should have already imported module.");
					var result = lastModule.getModuleVariable(this, variable);
					if(fiber.hasError()) {
						// RUNTIME_ERROR
						do {
							STORE_FRAME();
							runtimeError();
							if (fiber == null)
								return WREN_RESULT_RUNTIME_ERROR;
							fiber = this.fiber;
							LOAD_FRAME();
						} while (false);
					}
					PUSH(result);
				}
				case CODE_END:{
					// A CODE_END should always be preceded by a CODE_RETURN. If we get here,
					// the compiler generated wrong code.
					Utils.UNREACHABLE();
				}
			}
		}

		// We should only exit this function from an explicit return from CODE_RETURN
		// or a runtime error.
		Utils.UNREACHABLE();
		return WREN_RESULT_RUNTIME_ERROR;
	}
}
