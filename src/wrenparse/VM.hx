package wrenparse;

import wrenparse.Pointer.DataPointer;
import haxe.Int32;
import wrenparse.objects.ObjClass.Method;
import wrenparse.Value.ValuePointer;
import wrenparse.Value.ValueBuffer;
import wrenparse.IO.Buffer;
import polygonal.ds.ArrayList;
import wrenparse.objects.*;
import wrenparse.Compiler;
import wrenparse.IO.SymbolTable;

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

typedef WrenHandle = {
	?value:Value,

	?prev:WrenHandle,
	?next:WrenHandle,
}

// The type of an object stored in a slot.
//
// This is not necessarily the object's *class*, but instead its low level
// representation type.
enum WrenType {
	WREN_TYPE_BOOL;
	WREN_TYPE_NUM;
	WREN_TYPE_FOREIGN;
	WREN_TYPE_LIST;
	WREN_TYPE_MAP;
	WREN_TYPE_NULL;
	WREN_TYPE_STRING;

	// The object is of a type that isn't accessible by the C API.
	WREN_TYPE_UNKNOWN;
}

// A generic allocation function that handles all explicit memory management
// used by Wren. It's used like so:
//
// - To allocate new memory, [memory] is NULL and [newSize] is the desired
//   size. It should return the allocated memory or NULL on failure.
//
// - To attempt to grow an existing allocation, [memory] is the memory, and
//   [newSize] is the desired size. It should return [memory] if it was able to
//   grow it in place, or a new pointer if it had to move it.
//
// - To shrink memory, [memory] and [newSize] are the same as above but it will
//   always return [memory].
//
// - To free memory, [memory] will be the memory to free and [newSize] will be
//   zero. It should return NULL.
typedef WrenReallocateFn = (vm:VM, memory:Array<Obj>, size:Int) -> Array<Dynamic>;

/**
 * A function callable from Wren code, but implemented in Haxe.
 */
typedef WrenForeignMethodFn = (vm:VM) -> Void;

// A finalizer function for freeing resources owned by an instance of a foreign
// class. Unlike most foreign methods, finalizers do not have access to the VM
// and should not interact with it since it's in the middle of a garbage
// collection.
typedef WrenFinalizerFn = (data:Dynamic) -> Void;

// Gives the host a chance to canonicalize the imported module name,
// potentially taking into account the (previously resolved) name of the module
// that contains the import. Typically, this is used to implement relative
// imports.
typedef WrenResolveModuleFn = (vm:VM, importer:String, module:String) -> String;

// Loads and returns the source code for the module [name].
typedef WrenLoadModuleFn = (vm:VM, module:String) -> String;
typedef WrenBindForeignMethodFn = (vm:VM, module:String, className:String, isStatic:Bool, signature:String) -> WrenForeignMethodFn;

typedef WrenForeignClassMethods = {
	// The callback invoked when the foreign object is created.
	//
	// This must be provided. Inside the body of this, it must call
	// [wrenSetSlotNewForeign()] exactly once.
	?allocate:WrenForeignMethodFn,
	// The callback invoked when the garbage collector is about to collect a
	// foreign object's memory.
	//
	// This may be `NULL` if the foreign class does not need to finalize.
	?finalize:WrenFinalizerFn
}

typedef WrenBindForeignClassFn = (vm:VM, module:String, className:String) -> WrenForeignClassMethods;
typedef WrenErrorFn = (vm:VM, type:ErrorType, moduleName:String, line:Int, message:String) -> Void;

// Displays a string of text to the user.
typedef WrenWriteFn = (vm:VM, text:String) -> Void;

typedef VMConfig = {
	// The callback Wren uses to report errors.
	//
	// When an error occurs, this will be called with the module name, line
	// number, and an error message. If this is `NULL`, Wren doesn't report any
	// errors.
	?errorFn:WrenErrorFn,
	// The callback Wren will use to allocate, reallocate, and deallocate memory.
	//
	// If `NULL`, defaults to a built-in function that uses `realloc` and `free`.
	?reallocateFn:WrenReallocateFn,

	// The callback Wren uses to resolve a module name.
	//
	// Some host applications may wish to support "relative" imports, where the
	// meaning of an import string depends on the module that contains it. To
	// support that without baking any policy into Wren itself, the VM gives the
	// host a chance to resolve an import string.
	//
	// Before an import is loaded, it calls this, passing in the name of the
	// module that contains the import and the import string. The host app can
	// look at both of those and produce a new "canonical" string that uniquely
	// identifies the module. This string is then used as the name of the module
	// going forward. It is what is passed to [loadModuleFn], how duplicate
	// imports of the same module are detected, and how the module is reported in
	// stack traces.
	//
	// If you leave this function NULL, then the original import string is
	// treated as the resolved string.
	//
	// If an import cannot be resolved by the embedder, it should return NULL and
	// Wren will report that as a runtime error.
	//
	// Wren will take ownership of the string you return and free it for you, so
	// it should be allocated using the same allocation function you provide
	// above.
	?resolveModuleFn:WrenResolveModuleFn,
	// The callback Wren uses to load a module.
	//
	// Since Wren does not talk directly to the file system, it relies on the
	// embedder to physically locate and read the source code for a module. The
	// first time an import appears, Wren will call this and pass in the name of
	// the module being imported. The VM should return the soure code for that
	// module. Memory for the source should be allocated using [reallocateFn] and
	// Wren will take ownership over it.
	//
	// This will only be called once for any given module name. Wren caches the
	// result internally so subsequent imports of the same module will use the
	// previous source and not call this.
	//
	// If a module with the given name could not be found by the embedder, it
	// should return NULL and Wren will report that as a runtime error.
	?loadModuleFn:WrenLoadModuleFn,
	// The callback Wren uses to find a foreign method and bind it to a class.
	//
	// When a foreign method is declared in a class, this will be called with the
	// foreign method's module, class, and signature when the class body is
	// executed. It should return a pointer to the foreign function that will be
	// bound to that method.
	//
	// If the foreign function could not be found, this should return NULL and
	// Wren will report it as runtime error.
	?bindForeignMethodFn:WrenBindForeignMethodFn,
	// The callback Wren uses to find a foreign class and get its foreign methods.
	//
	// When a foreign class is declared, this will be called with the class's
	// module and name when the class body is executed. It should return the
	// foreign functions uses to allocate and (optionally) finalize the bytes
	// stored in the foreign object when an instance is created.
	?bindForeignClassFn:WrenBindForeignClassFn,
	// The callback Wren uses to display text when `System.print()` or the other
	// related functions are called.
	//
	// If this is `NULL`, Wren discards any printed text.
	?writeFn:WrenWriteFn,
	// The number of bytes Wren will allocate before triggering the first garbage
	// collection.
	//
	// If zero, defaults to 10MB.
	?initialHeapSize:Int,
	// After a collection occurs, the threshold for the next collection is
	// determined based on the number of bytes remaining in use. This allows Wren
	// to shrink its memory usage automatically after reclaiming a large amount
	// of memory.
	//
	// This can be used to ensure that the heap does not get too small, which can
	// in turn lead to a large number of collections afterwards as the heap grows
	// back to a usable size.
	//
	// If zero, defaults to 1MB.
	?minHeapSize:Int,
	// Wren will resize the heap automatically as the number of bytes
	// remaining in use after a collection changes. This number determines the
	// amount of additional memory Wren will use after a collection, as a
	// percentage of the current heap size.
	//
	// For example, say that this is 50. After a garbage collection, when there
	// are 400 bytes of memory still in use, the next collection will be triggered
	// after a total of 600 bytes are allocated (including the 400 already in
	// use.)
	//
	// Setting this to a smaller number wastes less memory, but triggers more
	// frequent garbage collections.
	//
	// If zero, defaults to 50.
	?heapGrowthPercent:Int,
	// User-defined data associated with the VM.
	?userData:Dynamic
}

class VM {
	public static var instance:VM;

	public var config:VMConfig;

	public var compiler:Compiler;

	public var numTempRoots:Int = 0;

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
	public var fiberClass:ObjClass;

	public var grayCapacity:Int;
	public var grayCount:Int;
	public var gray:Array<Obj>;

	public var methodNames:SymbolTable;

	public var bytesAllocated:Int;

	public static var INITIAL_CALL_FRAMES = 4;

	public var handles:WrenHandle;

	public var lastModule:ObjModule;

	public function new(?config:VMConfig) {
		this.config = config;
		if (config == null) {
			this.config = {};
			initConfiguration(this.config);
		} else {
			this.config = config;
		}
		this.tempRoots = [];
		this.modules = new ObjMap(this);
		this.methodNames = new SymbolTable(this);
		initializeCore();
	}

	function initializeCore() {
		var coreModule = new ObjModule(this, null);
		pushRoot(coreModule);
		// The core module's key is null in the module map.
		this.modules.set(this, Value.NULL_VAL(), coreModule.OBJ_VAL());
		popRoot();
	}

	public static function initConfiguration(config:VMConfig) {
		config.reallocateFn = null;
		config.resolveModuleFn = null;
		config.loadModuleFn = null;
		config.bindForeignMethodFn = null;
		config.bindForeignClassFn = null;
		config.writeFn = null;
		config.errorFn = null;
		config.initialHeapSize = 1024 * 1024 * 10;
		config.minHeapSize = 1024 * 1024;
		config.heapGrowthPercent = 50;
		config.userData = null;
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

		var fn = Compiler.compile(this, module, source, isExpression, printErrors);

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

	public function dumpCode(fn:ObjFn) {
		#if sys
		Sys.println('${fn.module.name == null ? "<core>" : fn.module.name.value.join("")}: ${fn.debug.name}');
		#else
		trace('${fn.module.name == null ? "<core>" : fn.module.name.value.join("")}: ${fn.debug.name}');
		#end

		var i = 0;
		var lastLine = -1;
		var offset = 0;
		while (offset != -1) {
			offset = dumpInstruction(fn, i, lastLine);
			i += offset;
		}
	}

	public function dumpInstruction(fn:ObjFn, i:Int, lastLine:Null<Int>):Int {
		var start = i;
		var bytecode = fn.code.data;
		var code:Code = bytecode.get(i);
		var line = fn.debug.sourceLines.data[i];
		var buf = new StringBuf();
		if (lastLine == null || lastLine != line) {
			buf.add(':$line');
			if (lastLine != -1)
				lastLine = line;
		} else {
			buf.add("     ");
		}
		buf.add(' ${i++} ');
		function READ_BYTE() {
			return bytecode.get(i++);
		}
		function READ_SHORT() {
			i += 2;
			return (bytecode.get(i - 2) << 8) | bytecode.get(i - 1);
		}
		function BYTE_INSTRUCTION(name:String) {
			buf.add('$name ${READ_BYTE()}\n');
		}

		function printf(s:String) {
			buf.add(s);
		}

		switch code {
			case CODE_POP:
				printf("POP\n");
			case CODE_CONSTANT:
				{
					var constant = READ_SHORT();
					buf.add('CONSTANT ${constant} \'');
					// trace(constant, fn.constants.data[constant]);

					buf.add(fn.constants.data[constant].dump());

					buf.add("'\n");
				}
			case CODE_NULL:
				printf("NULL\n");
			case CODE_FALSE:
				printf("FALSE\n");
			case CODE_TRUE:
				printf("TRUE\n");
			case CODE_LOAD_LOCAL_0:
				printf("LOAD_LOCAL_0\n");

			case CODE_LOAD_LOCAL_1:
				printf("LOAD_LOCAL_1\n");

			case CODE_LOAD_LOCAL_2:
				printf("LOAD_LOCAL_2\n");

			case CODE_LOAD_LOCAL_3:
				printf("LOAD_LOCAL_3\n");

			case CODE_LOAD_LOCAL_4:
				printf("LOAD_LOCAL_4\n");

			case CODE_LOAD_LOCAL_5:
				printf("LOAD_LOCAL_5\n");

			case CODE_LOAD_LOCAL_6:
				printf("LOAD_LOCAL_6\n");

			case CODE_LOAD_LOCAL_7:
				printf("LOAD_LOCAL_7\n");

			case CODE_LOAD_LOCAL_8:
				printf("LOAD_LOCAL_8\n");
			case CODE_LOAD_LOCAL:
				BYTE_INSTRUCTION("LOAD_LOCAL");
			case CODE_STORE_LOCAL:
				BYTE_INSTRUCTION("STORE_LOCAL");
			case CODE_LOAD_UPVALUE:
				BYTE_INSTRUCTION("LOAD_UPVALUE");
			case CODE_STORE_UPVALUE:
				BYTE_INSTRUCTION("STORE_UPVALUE");
			case CODE_LOAD_MODULE_VAR:
				{
					var slot = READ_SHORT();
					printf('LOAD_MODULE_VAR $slot \'${fn.module.variableNames.data[slot].value.join("")}\'');
				}
			case CODE_STORE_MODULE_VAR:
				{
					var slot = READ_SHORT();
					printf('STORE_MODULE_VAR $slot \'${fn.module.variableNames.data[slot].value.join("")}\'');
				}
			case CODE_LOAD_FIELD_THIS:
				BYTE_INSTRUCTION("LOAD_FIELD_THIS");
			case CODE_STORE_FIELD_THIS:
				BYTE_INSTRUCTION("STORE_FIELD_THIS");
			case CODE_LOAD_FIELD:
				BYTE_INSTRUCTION("LOAD_FIELD");
			case CODE_STORE_FIELD:
				BYTE_INSTRUCTION("STORE_FIELD");

			case CODE_CALL_0 | CODE_CALL_1 | CODE_CALL_2 | CODE_CALL_3 | CODE_CALL_4 | CODE_CALL_5 | CODE_CALL_6 | CODE_CALL_7 | CODE_CALL_8 | CODE_CALL_9 |
				CODE_CALL_10 | CODE_CALL_11 | CODE_CALL_12 | CODE_CALL_13 | CODE_CALL_14 | CODE_CALL_15 | CODE_CALL_16:
				{
					var numArgs = bytecode.get(i - 1) - CODE_CALL_0;

					var symbol = READ_SHORT();
					printf('CALL_${numArgs} $symbol \'${methodNames.data[symbol].value.join("")}\'');
				}
			case CODE_SUPER_0 | CODE_SUPER_1 | CODE_SUPER_2 | CODE_SUPER_3 | CODE_SUPER_4 | CODE_SUPER_5 | CODE_SUPER_6 | CODE_SUPER_7 | CODE_SUPER_8 |
				CODE_SUPER_9 | CODE_SUPER_10 | CODE_SUPER_11 | CODE_SUPER_12 | CODE_SUPER_13 | CODE_SUPER_14 | CODE_SUPER_15 | CODE_SUPER_16:
				{
					var numArgs = bytecode.get(i - 1) - CODE_SUPER_0;
					var symbol = READ_SHORT();
					var superclass = READ_SHORT();
					printf('SUPER_${numArgs} $symbol \'${methodNames.data[symbol].value.join("")}\' ${superclass}');
				}
			case CODE_RETURN:
				printf("RETURN\n");
			case CODE_END_MODULE:
				printf("END_MODULE\n");
			case CODE_END:
				printf("END\n");
			case CODE_JUMP_IF:
				{
					var offset = READ_SHORT();
					printf('JUMP_IF $offset to ${i + offset}');
				}
			case CODE_JUMP:
				{
					var offset = READ_SHORT();
					printf('JUMP $offset to ${i + offset}');
				}
			case CODE_LOOP:
				{
					var offset = READ_SHORT();
					printf('LOOP $offset to ${i - offset}');
				}
			case CODE_AND:
				{
					var offset = READ_SHORT();
					printf('AND $offset to ${i + offset}');
				}
			case CODE_OR:
				{
					var offset = READ_SHORT();
					printf('OR $offset to ${i + offset}');
				}
			case CODE_CLOSE_UPVALUE:
				printf("CLOSE_UPVALUE\n");
			case CODE_CLOSURE:
				{
					var constant = READ_SHORT();
					printf('CLOSURE $constant');

					printf(fn.constants.data[constant].dump());
					printf(" ");
					var loadedFn = fn.constants.data[constant].AS_FUN();
					for (j in 0...loadedFn.numUpvalues) {
						var isLocal = READ_BYTE();
						var index = READ_BYTE();
						if (j > 0)
							printf(", ");
						printf('${isLocal != 0 ? "local" : "upvalue"} $index');
					}
					printf("\n");
				}
			case CODE_CONSTRUCT:
				printf("CONSTRUCT\n");
			case CODE_FOREIGN_CONSTRUCT:
				printf("FOREIGN_CONSTRUCT\n");
			case CODE_CLASS:
				{
					var numFields = READ_BYTE();
					printf('CLASS $numFields fields\n');
				}
			case CODE_FOREIGN_CLASS:
				{
					printf("FOREIGN_CLASS\n");
				}
			case CODE_METHOD_INSTANCE:
				{
					var symbol = READ_SHORT();
					printf('METHOD_INSTANCE $symbol \'${methodNames.data[symbol].value.join("")}\' \n');
				}

			case CODE_METHOD_STATIC:
				{
					var symbol = READ_SHORT();
					printf('METHOD_STATIC $symbol \'${methodNames.data[symbol].value.join("")}\' \n');
				}
			case CODE_IMPORT_MODULE:
				{
					var name = READ_SHORT();
					printf('IMPORT_MODULE $name \'');
					printf(fn.constants.data[name].dump());
					printf("'\n");
				}

			case CODE_IMPORT_VARIABLE:
				{
					var variable = READ_SHORT();
					printf('IMPORT_VARIABLE $variable \'');
					printf(fn.constants.data[variable].dump());
					printf("'\n");
				}
			case _:
				{
					printf('UKNOWN! [${bytecode.get(i - 1)}]\n');
				}
		}
		#if (sys || nodejs)
		Sys.println('${buf.toString()}');
		#else
		trace('\n${buf.toString()}\n');
		#end

		if (code == CODE_END)
			return -1;
		return i - start;
	}

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
			this.gray = cast this.config.reallocateFn(this, this.gray, this.grayCapacity * cpp.Stdlib.sizeof(Obj));
			#else
			this.gray = cast this.config.reallocateFn(this, this.gray, this.grayCapacity * 256);
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
		this.bytesAllocated += cpp.Stdlib.sizeof(ObjClass);
		this.bytesAllocated += classObj.methods.capacity * cpp.Stdlib.sizeof(Method);
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
		this.bytesAllocated += cpp.Stdlib.sizeof(ObjClosure);
		this.bytesAllocated += cpp.Stdlib.sizeof(ObjUpvalue) * closure.numUpvalues;
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
		this.bytesAllocated += cpp.Stdlib.sizeof(ObjFiber);
		this.bytesAllocated += cpp.Stdlib.sizeof(ObjFiber) * fiber.frameCapacity;
		this.bytesAllocated += cpp.Stdlib.sizeof(Value) * fiber.stackCapacity;
		#else
		this.bytesAllocated += 256;
		this.bytesAllocated += 256 * fiber.frameCapacity;
		this.bytesAllocated += 256 * fiber.stackCapacity;
		#end
	}

	public function makeHandle(value:Value) {
		if (value.IS_OBJ())
			pushRoot(value.AS_OBJ());
		// Make a handle for it.
		var handle:WrenHandle = {};
		handle.value = value;
		if (value.IS_OBJ())
			popRoot();

		// Add it to the front of the linked list of handles.
		if (this.handles != null)
			this.handles.prev = handle;
		handle.prev = null;
		handle.next = this.handles;
		this.handles = handle;
		return handle;
	}

	public function call(method:WrenHandle) {
		Utils.ASSERT(method != null, "Method cannot be NULL.");
		Utils.ASSERT(method.value.IS_CLOSURE(), "Method must be a method handle.");
		Utils.ASSERT(this.fiber != null, "Must set up arguments for call first.");
		Utils.ASSERT(this.apiStack != null, "Must set up arguments for call first.");
		Utils.ASSERT(this.fiber.numFrames == 0, "Can not call from a foreign method.");

		var closure = method.value.AS_CLOSURE();
		Utils.ASSERT(this.fiber.stackTop.sub(fiber.stack) >= closure.arity, "Stack must have enough arguments for method.");

		// Clear the API stack. Now that wrenCall() has control, we no longer need
		// it. We use this being non-null to tell if re-entrant calls to foreign
		// methods are happening, so it's important to clear it out now so that you
		// can call foreign methods from within calls to wrenCall().
		this.apiStack = null;

		// Discard any extra temporary slots. We take for granted that the stub
		// function has exactly one slot for each argument.
		this.fiber.stackTop = this.fiber.stack.pointer(closure.maxSlots);

		this.fiber.callFunction(this, closure, 0);
		var result = runInterpreter(this.fiber);
		// If the call didn't abort, then set up the API stack to point to the
		// beginning of the stack so the host can access the call's return value.
		if (this.fiber != null)
			this.apiStack = this.fiber.stack;

		return result;
	}

	public function callHandle(signature:String) {
		Utils.ASSERT(signature != null, "Signature cannot be NULL.");
		var signatureLength = signature.length;
		Utils.ASSERT(signatureLength > 0, "Signature cannot be empty.");

		// Count the number parameters the method expects.
		var numParams = 0;
		if (signature.charAt(signatureLength - 1) == ')') {
			var i = signatureLength - 1;
			while (i > 0 && signature.charAt(i) != '(') {
				if (signature.charAt(i) == '_')
					numParams++;
				i--;
			}
		}
		// Count subscript arguments.
		if (signature.charAt(0) == '[') {
			var i = 0;
			while (i < signatureLength && signature.charAt(i) != ']') {
				if (signature.charAt(i) == '_')
					numParams++;
				i++;
			}
		}
		// Add the signatue to the method table.
		var method = this.methodNames.ensure(signature);
		// Create a little stub function that assumes the arguments are on the stack
		// and calls the method.
		var fn = new ObjFn(this, null, numParams + 1);

		// Wrap the function in a closure and then in a handle. Do this here so it
		// doesn't get collected as we fill it in.
		var value = makeHandle(fn.OBJ_VAL());
		value.value = ObjClosure.fromFn(this, fn).OBJ_VAL();
		fn.code.write(CODE_CALL_0 + numParams);
		fn.code.write((method >> 8) & 0xff);
		fn.code.write(method & 0xff);
		fn.code.write(CODE_RETURN);
		fn.code.write(CODE_END);
		fn.debug.sourceLines.fill(0, 5);
		fn.bindName(this, signature);
		return value;
	}

	public function releaseHandle(handle:WrenHandle) {
		Utils.ASSERT(handle != null, "Handle cannot be NULL.");
		// Update the VM's head pointer if we're releasing the first handle.
		if (this.handles == handle)
			this.handles = handle.next;

		// Unlink it from the list.
		if (handle.prev != null)
			handle.prev.next = handle.next;
		if (handle.next != null)
			handle.next.prev = handle.prev;

		// Clear it out. This isn't strictly necessary since we're going to free it,
		// but it makes for easier debugging.
		handle.prev = null;
		handle.next = null;
		handle.value = Value.NULL_VAL();
		// DEALLOCATE(vm, handle);
	}

	public function ensureSlots(numSlots:Int) {
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
		fiber.ensureStack(this, needed);

		fiber.stackTop.setValue(0, apiStack.value(numSlots));
	}

	public function getSlotCount() {
		if (apiStack == null)
			return 0;

		return fiber.stackTop.sub(apiStack);
	}

	/**
	 * Ensures that [slot] is a valid index into the API's stack of slots.
	 * @param slot
	 */
	public function validateApiSlot(slot:Int) {
		Utils.ASSERT(slot >= 0, "Slot cannot be negative.");
		Utils.ASSERT(slot < getSlotCount(), "Not that many slots.");
	}

	/**
	 * Gets the type of the object in [slot].
	 * @param slot
	 */
	public function getSlotType(slot:Int) {
		validateApiSlot(slot);
		if (this.apiStack.value(slot).IS_BOOL())
			return WREN_TYPE_BOOL;
		if (this.apiStack.value(slot).IS_NUM())
			return WREN_TYPE_NUM;
		if (this.apiStack.value(slot).IS_FOREIGN())
			return WREN_TYPE_FOREIGN;
		if (this.apiStack.value(slot).IS_LIST())
			return WREN_TYPE_LIST;
		if (this.apiStack.value(slot).IS_MAP())
			return WREN_TYPE_MAP;
		if (this.apiStack.value(slot).IS_NULL())
			return WREN_TYPE_NULL;
		if (this.apiStack.value(slot).IS_STRING())
			return WREN_TYPE_STRING;

		return WREN_TYPE_UNKNOWN;
	}

	public function getSlotBool(slot:Int) {
		validateApiSlot(slot);
		Utils.ASSERT(this.apiStack.value(slot).IS_BOOL(), "Slot must hold a bool.");
		return this.apiStack.value(slot).AS_BOOL();
	}

	public function getSlotString(slot:Int):String {
		validateApiSlot(slot);
		Utils.ASSERT(this.apiStack.value(slot).IS_STRING(), "Slot must hold a string.");
		var string = this.apiStack.value(slot).AS_STRING();
		return string.value.join("");
	}

	public function getSlotDouble(slot:Int):Float {
		validateApiSlot(slot);
		Utils.ASSERT(this.apiStack.value(slot).IS_NUM(), "Slot must hold a number.");
		var num = this.apiStack.value(slot).AS_NUM();
		return num;
	}

	public function getSlotForeign(slot:Int) {
		validateApiSlot(slot);
		Utils.ASSERT(this.apiStack.value(slot).IS_FOREIGN(), "Slot must hold a foreign instance.");

		this.apiStack.value(slot).AS_FOREIGN();
	}

	public function getSlotHandle(slot:Int) {
		validateApiSlot(slot);
		return makeHandle(apiStack.value(slot));
	}

	/**
	 * Stores [value] in [slot] in the foreign call stack.
	 * @param slot
	 * @param value
	 */
	public function setSlot(slot:Int, value:Value) {
		validateApiSlot(slot);
		apiStack.setValue(slot, value);
	}

	public function setSlotBool(slot:Int, value:Bool) {
		setSlot(slot, Value.BOOL_VAL(value));
	}

	public function setSlotString(slot:Int, string:String) {
		Utils.ASSERT(string != null, "String cannot be NULL.");
		setSlot(slot, ObjString.newString(this, string));
	}

	public function setSlotNewForeign(slot:Int, classSlot:Int, data:Dynamic) {
		validateApiSlot(slot);
		validateApiSlot(classSlot);

		Utils.ASSERT(apiStack.value(classSlot).IS_CLASS(), "Slot must hold a class.");
		var classObj = apiStack.value(classSlot).AS_CLASS();
		Utils.ASSERT(classObj.numFields == -1, "Class must be a foreign class.");
		var foreign = new ObjForeign(this, classObj, data);
		apiStack.setValue(slot, foreign.OBJ_VAL());

		return foreign.data;
	}

	public function setSlotNewList(slot:Int) {
		setSlot(slot, (new ObjList(this, 0)).OBJ_VAL());
	}

	public function setSlotNewMap(slot:Int) {
		setSlot(slot, (new ObjMap(this)).OBJ_VAL());
	}

	public function setSlotNull(slot:Int) {
		setSlot(slot, Value.NULL_VAL());
	}

	public function setSlotHandle(slot:Int, handle:WrenHandle) {
		Utils.ASSERT(handle != null, "Handle cannot be NULL.");
		setSlot(slot, handle.value);
	}

	public function getListCount(slot:Int) {
		validateApiSlot(slot);
		Utils.ASSERT(apiStack.value(slot).IS_LIST(), "Slot must hold a list.");
		var elements = apiStack.value(slot).AS_LIST().elements;
		return elements.count;
	}

	public function getListElement(listSlot:Int, index:Int, elementSlot:Int) {
		validateApiSlot(listSlot);
		validateApiSlot(elementSlot);
		Utils.ASSERT(apiStack.value(listSlot).IS_LIST(), "Slot must hold a list.");

		var elements = apiStack.value(listSlot).AS_LIST().elements;
		apiStack.setValue(elementSlot, elements.data[index]);
	}

	public function insertInList(listSlot:Int, index:Int, elementSlot:Int) {
		validateApiSlot(listSlot);
		validateApiSlot(elementSlot);
		Utils.ASSERT(apiStack.value(listSlot).IS_LIST(), "Slot must hold a list.");
		var list = apiStack.value(listSlot).AS_LIST();
		// Negative indices count from the end.
		if (index < 0)
			index = list.elements.count + 1 + index;
		Utils.ASSERT(index <= list.elements.count, "Index out of bounds.");
		list.insert(this, apiStack.value(elementSlot), index);
	}

	public function getMapCount(slot:Int) {
		validateApiSlot(slot);
		Utils.ASSERT(apiStack.value(slot).IS_MAP(), "Slot must hold a map.");
		var map = apiStack.value(slot).AS_MAP();
		return map.count;
	}

	public function getMapContainsKey(mapSlot:Int, keySlot:Int):Bool {
		validateApiSlot(mapSlot);
		validateApiSlot(keySlot);
		Utils.ASSERT(apiStack.value(mapSlot).IS_MAP(), "Slot must hold a map.");
		var key = apiStack.value(keySlot);
		if (!ObjMap.validateKey(this, key))
			return false;
		var map = apiStack.value(mapSlot).AS_MAP();
		var value = map.get(this, key);
		return !value.IS_UNDEFINED();
	}

	public function getMapValue(mapSlot:Int, keySlot:Int, valueSlot:Int) {
		validateApiSlot(mapSlot);
		validateApiSlot(keySlot);
		validateApiSlot(valueSlot);
		Utils.ASSERT(apiStack.value(mapSlot).IS_MAP(), "Slot must hold a map.");
		var map = apiStack.value(mapSlot).AS_MAP();
		var key = apiStack.value(keySlot);
		var value = map.get(this, key);
		if (value.IS_UNDEFINED()) {
			value = Value.NULL_VAL();
		}
		apiStack.setValue(valueSlot, value);
	}

	public function setMapValue(mapSlot:Int, keySlot:Int, valueSlot:Int) {
		validateApiSlot(mapSlot);
		validateApiSlot(keySlot);
		validateApiSlot(valueSlot);
		Utils.ASSERT(apiStack.value(mapSlot).IS_MAP(), "Must insert into a map.");
		var key = apiStack.value(keySlot);
		if (!ObjMap.validateKey(this, key)) {
			return;
		}

		var value = apiStack.value(valueSlot);
		var map = apiStack.value(mapSlot).AS_MAP();
		map.set(this, key, value);
	}

	public function removeMapValue(mapSlot:Int, keySlot:Int, removedValueSlot:Int) {
		validateApiSlot(mapSlot);
		validateApiSlot(keySlot);
		validateApiSlot(removedValueSlot);
		Utils.ASSERT(apiStack.value(mapSlot).IS_MAP(), "Slot must hold a map.");
		var key = apiStack.value(keySlot);
		if (!ObjMap.validateKey(this, key)) {
			return;
		}
		var map = apiStack.value(mapSlot).AS_MAP();
		var removed = map.removeKey(this, key);
		setSlot(removedValueSlot, removed);
	}

	public function getVariable(module:String, name:String, slot:Int) {
		Utils.ASSERT(module != null, "Module cannot be NULL.");
		Utils.ASSERT(name != null, "Variable name cannot be NULL.");

		var moduleName = ObjString.format(this, "$", [module]);
		pushRoot(moduleName.AS_OBJ());
		var moduleObj = getModule(moduleName);
		Utils.ASSERT(moduleObj != null, "Could not find module.");
		popRoot(); // moduleName.

		var variableSlot = moduleObj.variableNames.find(name);
		Utils.ASSERT(variableSlot != -1, "Could not find variable.");
		setSlot(slot, moduleObj.variables.data[variableSlot]);
	}

	public function abortFiber(slot:Int) {
		validateApiSlot(slot);
		fiber.error = apiStack.value(slot);
	}

	public function getUserData() {
		return config.userData;
	}

	public function setUserData(userData:Dynamic) {
		config.userData = userData;
	}

	public function checkArity(value:Value, numArgs:Int):Bool {
		Utils.ASSERT(value.IS_CLOSURE(), "Receiver must be a closure.");
		var fn:ObjFn = cast value.AS_CLOSURE();
		// We only care about missing arguments, not extras. The "- 1" is because
		// numArgs includes the receiver, the function itself, which we don't want to
		// count.
		if (numArgs - 1 >= fn.arity)
			return true;
		fiber.error = ObjString.CONST_STRING(this, "Function expects more arguments.");
		return false;
	}

	public function runtimeError() {
		Utils.ASSERT(fiber.hasError(), "Should only call this after an error.");
		var current = fiber;
		var error = current.error;
		while (current != null) {
			// Every fiber along the call chain gets aborted with the same error.
			current.error = error;

			// If the caller ran this fiber using "try", give it the error and stop.
			if (current.state == FIBER_TRY) {
				// Make the caller's try method return the error message.
				current.caller.stackTop.setValue(-1, fiber.error);
				fiber = current.caller;
				return;
			}
			// Otherwise, unhook the caller since we will never resume and return to it.
			var caller = current.caller;
			current.caller = null;
			current = caller;
		}
		// If we got here, nothing caught the error, so show the stack trace.
		debugPrintStackTrace();
		fiber = null;
		apiStack = null;
	}

	public function debugPrintStackTrace() {
		// Bail if the host doesn't enable printing errors.
		if (config.errorFn == null)
			return;
		var fiber = this.fiber;
		if (fiber.error.IS_STRING()) {
			config.errorFn(this, WREN_ERROR_RUNTIME, null, -1, fiber.error.AS_CSTRING());
		} else {
			// TODO: Print something a little useful here. Maybe the name of the error's
			// class?
			config.errorFn(this, WREN_ERROR_RUNTIME, null, -1, "[error object]");
		}
		var i = fiber.numFrames - 1;

		while (i >= 0) {
			var frame = fiber.frames[i];
			var fn:ObjFn = cast frame.closure;
			// Skip over stub functions for calling methods from the Haxe API.
			if (fn.module == null)
				continue;
			// The built-in core module has no name. We explicitly omit it from stack
			// traces since we don't want to highlight to a user the implementation
			// detail of what part of the core module is written in Haxe and what is Wren.
			if (fn.module.name == null)
				continue;
			// -1 because IP has advanced past the instruction that it just executed.
			var dataPointer:DataPointer = new DataPointer(fn.code.data);
			var line = fn.debug.sourceLines.data[frame.ip.sub(dataPointer.pointer(-1))];
			config.errorFn(this, WREN_ERROR_RUNTIME, fn.module.name.value.join(""), line, fn.debug.name);
			i--;
		}
	}

	/**
	 * Creates a new class.
	 *
	 * If [numFields] is -1, the class is a foreign class. The name and superclass
	 * should be on top of the fiber's stack. After calling this, the top of the
	 * stack will contain the new class.
	 *
	 * Aborts the current fiber if an error occurs.
	 * @param numFields
	 * @param module
	 */
	public function createClass(numFields:Int, module:ObjModule) {
		// Pull the name and superclass off the stack.
		var name = fiber.stackTop.value(-2);
		var superclass = fiber.stackTop.value(-1);
		// We have two values on the stack and we are going to leave one, so discard
		// the other slot.
		fiber.stackTop.drop();
		fiber.error = validateSuperclass(name, superclass, numFields);
		if (fiber.hasError())
			return;
		var classObj = ObjClass.newClass(this, superclass.AS_CLASS(), numFields, name.AS_STRING());
		fiber.stackTop.setValue(-1, classObj.OBJ_VAL());
		if (numFields == -1)
			classObj.bindForeignClass(this, module);
	}

	/**
	 * Defines [methodValue] as a method on [classObj].
	 *
	 * Handles both foreign methods where [methodValue] is a string containing the
	 * method's signature and Wren methods where [methodValue] is a function.
	 *
	 * Aborts the current fiber if the method is a foreign method that could not be
	 * found.
	 * @param methodType
	 * @param symbol
	 * @param module
	 * @param classObj
	 * @param methodValue
	 */
	public function bindMethod(methodType:Code, symbol:Int, module:ObjModule, classObj:ObjClass, methodValue:Value) {
		var className = classObj.name.value.join("");
		if (methodType == CODE_METHOD_STATIC)
			classObj = classObj.classObj;
		var method:ObjClass.Method = null;
		if (methodValue.IS_STRING()) {
			var name = methodValue.AS_CSTRING();
			method = new Method(METHOD_FOREIGN);
			method.as.foreign = findForeignMethod(module.name.value.join(""), className, methodType == CODE_METHOD_STATIC, name);
			if (method.as.foreign == null) {
				fiber.error = ObjString.format(this, "Could not find foreign method '@' for class $ in module '$'.",
					[methodValue, classObj.name.value.join(""), module.name.value.join("")]);
				return;
			}
		} else {
			method = new Method(METHOD_BLOCK);
			method.as.closure = methodValue.AS_CLOSURE();

			// Patch up the bytecode now that we know the superclass.
			classObj.bindMethodCode(method.as.closure);
		}

		classObj.bindMethod(this, symbol, method);
	}

	public function findForeignMethod(moduleName:String, className:String, isStatic:Bool, signature:String):WrenForeignMethodFn {
		var method = null;
		if (config.bindForeignMethodFn != null) {
			method = config.bindForeignMethodFn(this, moduleName, className, isStatic, signature);
		}
		// If the host didn't provide it, see if it's an optional one.
		if (method == null) {}

		return method;
	}

	/**
	 * Let the host resolve an imported module name if it wants to.
	 * @param name
	 * @return Value
	 */
	public function resolveModule(name:Value):Value {
		// If the host doesn't care to resolve, leave the name alone.
		if (this.config.resolveModuleFn == null)
			return name;
		var fiber = this.fiber;
		var fn:ObjFn = fiber.frames[fiber.numFrames - 1].closure;
		var importer = fn.module.name;
		var resolved = config.resolveModuleFn(this, importer.value.join(""), name.AS_CSTRING());

		if (resolved == null) {
			fiber.error = ObjString.format(this, "Could not resolve module '@' imported from '@'.", [name, importer.OBJ_VAL()]);
			return Value.NULL_VAL();
		}
		// If they resolved to the exact same string, we don't need to copy it.
		if (resolved == name.AS_CSTRING())
			return name;
		// Copy the string into a Wren String object.
		name = ObjString.newString(this, resolved);
		// DEALLOCATE(vm, (char*)resolved);
		return name;
	}

	public function importModule(name:Value):Value {
		name = resolveModule(name);

		// If the module is already loaded, we don't need to do anything.
		var existing = modules.get(this, name);

		if (!existing.IS_UNDEFINED())
			return existing;
		pushRoot(name.AS_OBJ());
		var source:String = null;
		var allocatedSource = true;
		// Let the host try to provide the module.
		if (config.loadModuleFn != null) {
			source = config.loadModuleFn(this, name.AS_CSTRING());
		}

		// If the host didn't provide it, see if it's a built in optional module.
		if (source == null) {
			// 	  ObjString* nameString = AS_STRING(name);
			//   #if WREN_OPT_META
			// 	  if (strcmp(nameString->value, "meta") == 0) source = wrenMetaSource();
			//   #endif
			//   #if WREN_OPT_RANDOM
			// 	  if (strcmp(nameString->value, "random") == 0) source = wrenRandomSource();
			//   #endif

			// 	  // TODO: Should we give the host the ability to provide strings that don't
			// 	  // need to be freed?
			allocatedSource = false;
		}
		if (source == null) {
			fiber.error = ObjString.format(this, "Could not load module '@'.", [name]);
			popRoot();

			return Value.NULL_VAL();
		}

		var moduleClosure = compileInModule(name, source, false, true);
		// Modules loaded by the host are expected to be dynamically allocated with
		// ownership given to the VM, which will free it. The built in optional
		// modules are constant strings which don't need to be freed.
		if (allocatedSource) {} // DEALLOCATE(vm, (char*)source);

		if (moduleClosure == null) {
			fiber.error = ObjString.format(this, "Could not compile module '@'.", [name]);
			popRoot(); // name.
			return Value.NULL_VAL();
		}

		popRoot();
		// Return the closure that executes the module.
		return moduleClosure.OBJ_VAL();
	}

	/**
	 * Verifies that [superclassValue] is a valid object to inherit from. That
	 * means it must be a class and cannot be the class of any built-in type.
	 *
	 * Also validates that it doesn't result in a class with too many fields and
	 * the other limitations foreign classes have.
	 *
	 * If successful, returns `null`. Otherwise, returns a string for the runtime
	 * error message.
	 * @param name
	 * @param superclassValue
	 * @param numFields
	 */
	public function validateSuperclass(name:Value, superclassValue:Value, numFields:Int):Value {
		// Make sure the superclass is a class.
		if (!superclassValue.IS_CLASS()) {
			return ObjString.format(this, "Class '@' cannot inherit from a non-class object.", [name]);
		}

		// Make sure it doesn't inherit from a sealed built-in type. Primitive methods
		// on these classes assume the instance is one of the other Obj___ types and
		// will fail horribly if it's actually an ObjInstance.

		var superclass = superclassValue.AS_CLASS();
		if (superclass == this.classClass
			|| superclass == this.fiberClass
			|| superclass == this.fnClass
			|| // Includes OBJ_CLOSURE.
			superclass == this.listClass
			|| superclass == this.mapClass
			|| superclass == this.rangeClass
			|| superclass == this.stringClass) {
			return ObjString.format(this, "Class '@' cannot inherit from built-in class '@'.", [name, superclass.name.OBJ_VAL()]);
		}

		if (superclass.numFields == -1) {
			return ObjString.format(this, "Class '@' cannot inherit from foreign class '@'.", [name, superclass.name.OBJ_VAL()]);
		}
		if (numFields == -1 && superclass.numFields > 0) {
			return ObjString.format(this, "Foreign class '@' may not inherit from a class with fields.", [name]);
		}

		if (superclass.numFields + numFields > Compiler.MAX_FIELDS) {
			return ObjString.format(this, "Class '@' may not have more than 255 fields, including inherited ones.", [name]);
		}

		return Value.NULL_VAL();
	}

	public function interpret(module:String, source:String) {
		var closure = compileSource(module, source, false, true);
		if (closure == null)
			return WREN_RESULT_COMPILE_ERROR;
		pushRoot(cast closure);
		var fiber = new ObjFiber(this, closure);

		popRoot(); // closure.

		this.apiStack = null;
		#if WREN_INTERPRET
		return runInterpreter(fiber);
		#else
		return WREN_RESULT_SUCCESS;
		#end
	}

	public function runInterpreter(fiber:ObjFiber):WrenInterpretResult {
		// Remember the current fiber so we can find it if a GC happens.
		this.fiber = fiber;

		this.fiber.state = FIBER_ROOT;

		var frame:ObjClosure.CallFrame = null;

		var stackStart:ValuePointer = null;
		var ip:DataPointer = null;
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
							if (!this.checkArity(args.value(), numArgs)) {
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
							fiber.callForeign(this, method.as.foreign, numArgs);
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
				case CODE_LOAD_LOCAL_0 | CODE_LOAD_LOCAL_1 | CODE_LOAD_LOCAL_2 | CODE_LOAD_LOCAL_3 | CODE_LOAD_LOCAL_4 | CODE_LOAD_LOCAL_5 |
					CODE_LOAD_LOCAL_6 | CODE_LOAD_LOCAL_7 | CODE_LOAD_LOCAL_8:
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
				case CODE_NULL:
					PUSH(Value.NULL_VAL());
					continue;
				case CODE_FALSE:
					PUSH(Value.BOOL_VAL(false));
					continue;
				case CODE_TRUE:
					PUSH(Value.BOOL_VAL(true));
					continue;
				case CODE_STORE_LOCAL:
					stackStart.setValue(READ_BYTE(), PEEK());
					continue;
				case CODE_CONSTANT:
					PUSH(fn.constants.data[READ_SHORT()]);
					continue;
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
						fiber.closeUpvalues(stackStart);
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
						stackStart.setValue(0, ObjInstance.newInstance(this, stackStart.value().AS_CLASS()));
						continue;
					}
				case CODE_FOREIGN_CONSTRUCT:
					{
						Utils.ASSERT(stackStart.value().IS_CLASS(), "'this' should be a class.");
						fiber.createForeign(this, stackStart);
						continue;
					}
				case CODE_CLOSURE:
					{
						// Create the closure and push it on the stack before creating upvalues
						// so that it doesn't get collected.
						var func = fn.constants.data[READ_SHORT()].AS_FUN();
						var closure = ObjClosure.fromFn(this, func);
						PUSH(closure.OBJ_VAL());
						// Capture upvalues, if any.
						for (i in 0...func.numUpvalues) {
							var isLocal:Null<Int> = READ_BYTE();
							var index = READ_BYTE();
							if (isLocal != null) {
								// Make an new upvalue to close over the parent's local variable.
								closure.upValues[i] = fiber.captureUpvalues(this, frame.stackStart.pointer(index));
							} else {
								// Use the same upvalue as the current call frame.
								closure.upValues[i] = frame.closure.upValues[index];
							}
						}
						continue;
					}
				case CODE_CLASS:
					{
						createClass(READ_BYTE(), null);
						if (fiber.hasError()) {
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
				case CODE_FOREIGN_CLASS:
					{
						createClass(-1, fn.module);
						if (fiber.hasError()) {
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
				case CODE_METHOD_INSTANCE | CODE_METHOD_STATIC:
					{
						var symbol = READ_SHORT();
						var classObj = PEEK().AS_CLASS();
						var method = PEEK2();
						bindMethod(instruction, symbol, fn.module, classObj, method);
						if (fiber.hasError()) {
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
				case CODE_END_MODULE:
					{
						this.lastModule = fn.module;
						PUSH(Value.NULL_VAL());
						continue;
					}
				case CODE_IMPORT_MODULE:
					{
						// Make a slot on the stack for the module's fiber to place the return
						// value. It will be popped after this fiber is resumed. Store the
						// imported module's closure in the slot in case a GC happens when
						// invoking the closure.
						PUSH(importModule(fn.constants.data[READ_SHORT()]));
						if (fiber.hasError()) {
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
						if (PEEK().IS_CLOSURE()) {
							STORE_FRAME();
							var closure = PEEK().AS_CLOSURE();
							fiber.callFunction(this, closure, 1);
							LOAD_FRAME();
						} else {
							// The module has already been loaded. Remember it so we can import
							// variables from it if needed.
							this.lastModule = PEEK().AS_MODULE();
						}
						continue;
					}
				case CODE_IMPORT_VARIABLE:
					{
						var variable = fn.constants.data[READ_SHORT()];
						Utils.ASSERT(this.lastModule != null, "Should have already imported module.");
						var result = this.lastModule.getModuleVariable(this, variable);
						if (fiber.hasError()) {
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
						continue;
					}
				case CODE_END:
					{
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
