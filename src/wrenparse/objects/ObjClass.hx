package wrenparse.objects;

import wrenparse.Compiler.Code;
import wrenparse.IO.Buffer;
import wrenparse.objects.ObjClosure;
import wrenparse.Value.Primitive;
import wrenparse.VM;

enum MethodType {
	// A primitive method implemented in C in the VM. Unlike foreign methods,
	// this can directly manipulate the fiber's stack.
	METHOD_PRIMITIVE;

	// A primitive that handles .call on Fn.
	METHOD_FUNCTION_CALL;
	// A externally-defined Haxe method.
	METHOD_FOREIGN;
	// A normal user-defined method.
	METHOD_BLOCK;
	// No method for the given symbol.
	METHOD_NONE;
}

typedef MethodAs = {
	?primitive:Primitive,
	?foreign:Dynamic,
	// WrenForeignMethodFn
	?closure:ObjClosure
}

class Method {
	public var type:MethodType;
	public var as:MethodAs;

	public function new(type:MethodType) {
		this.type = type;
	}
}

typedef MethodBuffer = Buffer<Method>;

class ObjClass extends Obj {
	public var superClass:ObjClass;

	/**
	 * The number of fields needed for an instance of this class, including all
	 * of its superclass fields.
	 */
	public var numFields:Int;

	/**
	 * The table of methods that are defined in or inherited by this class.
	 * Methods are called by symbol, and the symbol directly maps to an index in
	 * this table. This makes method calls fast at the expense of empty cells in
	 * the list for methods the class doesn't support.
	 *
	 * You can think of it as a hash table that never has collisions but has a
	 * really low load factor. Since methods are pretty small (just a type and a
	 * pointer), this should be a worthwhile trade-off.
	 */
	public var methods:MethodBuffer;

	/**
	 * The name of the class
	 */
	public var name:ObjString;

	public function new(vm:VM, numFields:Int, name:ObjString) {
		this.type = OBJ_CLASS;
		this.superClass = null;
		this.numFields = numFields;
		this.name = name;

		super(vm, this.type, classObj);

		vm.pushRoot(this);
		this.methods = new MethodBuffer(vm);
		vm.popRoot();
	}

	public function bindSuperclass(vm:VM, superClass:ObjClass) {
		if (superClass == null)
			throw "Must have superclass.";
		this.superClass = superClass;
		// Include the superclass in the total number of fields.
		if (numFields != -1) {
			numFields += superClass.numFields;
		} else {
			if (superClass.numFields != 0)
				throw "A foreign class cannot inherit from a class with fields.";
		}

		// Inherit methods from its superclass.
		for (i in 0...superClass.methods.count) {
			bindMethod(vm, i, superClass.methods.data[i]);
		}
	}

	public static function newClass(vm:VM, superclass:ObjClass, numFields:Int, name:ObjString):ObjClass {
		// Create the metaclass
		var metaclassName = ObjString.format(vm, "@ metaclass", [name.OBJ_VAL()]);
		vm.pushRoot(metaclassName.as.obj);
		var metaclass:ObjClass = new ObjClass(vm, numFields, name);
		metaclass.classObj = vm.classClass;
		vm.popRoot();

		// Make sure the metaclass isn't collected when we allocate the class.
		vm.pushRoot(metaclass);

		// Metaclasses always inherit Class and do not parallel the non-metaclass
		// hierarchy.
		metaclass.bindSuperclass(vm, vm.classClass);
		var classObj = new ObjClass(vm, numFields, name);
		// Make sure the class isn't collected while the inherited methods are being
		// bound.
		vm.pushRoot(classObj);
		classObj.classObj = metaclass;
		classObj.bindSuperclass(vm, superclass);
		vm.popRoot();
		vm.popRoot();

		return classObj;
	}

	public function bindMethod(vm:VM, symbol:Int, method:Method) {
		// Make sure the buffer is big enough to contain the symbol's index.
		if (symbol >= this.methods.count) {
			var noMethod:Method = new Method(METHOD_NONE);

			this.methods.fill(noMethod, symbol - this.methods.count + 1);
		}

		this.methods.data[symbol] = method;
	}

	public function bindMethodCode(fn:ObjFn) {
		var ip = 0;
		while (true) {
			var instruction:Code = fn.code.data[ip];
			switch instruction {
				case CODE_LOAD_FIELD | CODE_STORE_FIELD | CODE_LOAD_FIELD_THIS | CODE_STORE_FIELD_THIS:
					{
						// Shift this class's fields down past the inherited ones. We don't
						// check for overflow here because we'll see if the number of fields
						// overflows when the subclass is created.
						fn.code.data[ip + 1] += this.superClass.numFields;
					}
				case CODE_SUPER_0 | CODE_SUPER_1 | CODE_SUPER_2 | CODE_SUPER_3 | CODE_SUPER_4 | CODE_SUPER_5 | CODE_SUPER_6 | CODE_SUPER_7 | CODE_SUPER_8 |
					CODE_SUPER_9 | CODE_SUPER_10 | CODE_SUPER_11 | CODE_SUPER_12 | CODE_SUPER_13 | CODE_SUPER_14 | CODE_SUPER_15 | CODE_SUPER_16:
					{
						// Fill in the constant slot with a reference to the superclass.
						var constant = (fn.code.data[ip + 3] << 8) | fn.code.data[ip + 4];
						fn.constants.data[constant] = this.superClass.OBJ_VAL();
					}
				case CODE_CLOSURE:
					{
						// Bind the nested closure too.

						var constant = (fn.code.data[ip + 1] << 8) | fn.code.data[ip + 2];
						bindMethodCode(fn.constants.data[constant].AS_FUN());
						break;
					}

				case CODE_END:
					return;
				case _:
			}
			ip += 1 + Compiler.getByteCountForArguments(fn.code.data, fn.constants.data, ip);
		}
	}

	

	public function bindForeignClass(vm:VM, module:ObjModule) {
		var methods:VM.WrenForeignClassMethods = {};
		// Check the optional built-in module first so the host can override it.
		if (vm.config.bindForeignClassFn != null) {
			methods = vm.config.bindForeignClassFn(vm, module.name.value.join(""), classObj.name.value.join(""));
		}

		// If the host didn't provide it, see if it's a built in optional module.
		if (methods.allocate == null && methods.finalize == null) {}
		var method = new Method(METHOD_FOREIGN);
		// Add the symbol even if there is no allocator so we can ensure that the
		// symbol itself is always in the symbol table.
		var symbol = vm.methodNames.ensure("<allocate>");
		if (methods.allocate != null) {
			method.as.foreign = methods.allocate;
			bindMethod(vm, symbol, method);
		}
		// Add the symbol even if there is no finalizer so we can ensure that the
		// symbol itself is always in the symbol table.
		symbol = vm.methodNames.ensure("<finalize>");
		if (methods.finalize != null) {
			method.as.foreign = methods.finalize;
			bindMethod(vm, symbol, method);
		}
	}

	/**
	 * Aborts the current fiber with an appropriate method not found error for a
	 * method with [symbol] on [classObj].
	 * @param vm
	 * @param symbold
	 */
	public function methodNotFound(vm:VM, symbol:Int) {
		vm.fiber.error = ObjString.format(vm, "@ does not implement '$'.", [classObj.name.OBJ_VAL(), vm.methodNames.data[symbol].value.join("")]);
	}
}
