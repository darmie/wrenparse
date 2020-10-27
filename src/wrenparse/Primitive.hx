package wrenparse;

import haxe.io.BytesOutput;
import haxe.io.Bytes;
import haxe.io.FPHelper;
import haxe.Constraints.Function;
import wrenparse.objects.ObjClass.Method;
import wrenparse.objects.ObjClass.MethodType;
import wrenparse.objects.*;
import wrenparse.IO.SymbolTable;
import wrenparse.Value.ValuePointer;

/**
 * The type of a primitive function.
 *
 * Primitives are similiar to foreign functions, but have more direct access to
 * VM internals. It is passed the arguments in [args]. If it returns a value,
 * it places it in `args[0]` and returns `true`. If it causes a runtime error
 * or modifies the running fiber, it returns `false`.
 */
typedef PrimitiveFunc = (vm:VM, args:ValuePointer) -> Bool;

class Primitive {
	/**
	 * Binds a primitive method named [name] (in Wren) implemented using Haxe function
	 * [fn] to `ObjClass` [cls].
	 * @param vm
	 * @param cls
	 * @param name
	 * @param func
	 * @return
	 */
	public static inline function PRIMITIVE(vm:VM, cls:ObjClass, name:String, func:PrimitiveFunc) {
		var symbol = vm.methodNames.ensure(name);
		var method = new Method(METHOD_PRIMITIVE);
		method.as.primitive = func;
		cls.bindMethod(vm, symbol, method);
	}

	/**
	 * Binds a primitive method named [name] (in Wren) implemented using C function
	 * [fn] to `ObjClass` [cls], but as a FN call.
	 * @param vm
	 * @param cls
	 * @param name
	 * @param func
	 */
	public static inline function FUNCTION_CALL(vm:VM, cls:ObjClass, name:String, func:PrimitiveFunc) {
		do {
			var symbol = vm.methodNames.ensure(name);
			var method = new Method(METHOD_FUNCTION_CALL);
			method.as.primitive = func;
			cls.bindMethod(vm, symbol, method);
		} while (false);
	}

	public static function object_not(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(false));
		return true;
	}

	public static function object_same(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(Value.equal(args.value(1), args.value(2))));
		return true;
	}

	public static function object_eqeq(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(Value.equal(args.value(0), args.value(1))));
		return true;
	}

	public static function object_bangeq(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(!Value.equal(args.value(0), args.value(1))));
		return true;
	}

	public static function object_is(vm:VM, args:ValuePointer):Bool {
		if (!args.value(1).IS_CLASS()) {
			do {
				vm.fiber.error = ObjString.CONST_STRING(vm, "Right operand must be a class.");
				return false;
			} while (false);
		}

		var classObj = Value.getClass(vm, args.value(0));
		var baseClassObj = args.value(1).AS_CLASS();

		// Walk the superclass chain looking for the class.
		do {
			if (baseClassObj == classObj) {
				args.setValue(0, Value.BOOL_VAL(true));
				return true;
			}

			classObj = classObj.superClass;
		} while (classObj != null);

		args.setValue(0, Value.BOOL_VAL(false));
		return false;
	}

	public static function object_toString(vm:VM, args:ValuePointer):Bool {
		var obj = args.value(0).AS_OBJ();
		var name = obj.classObj.name.OBJ_VAL();
		args.setValue(0, ObjString.format(vm, "instance of @", [name]));
		return true;
	}

	public static function object_type(vm:VM, args:ValuePointer):Bool {
		var cls = Value.getClass(vm, args.value(0));
		args.setValue(0, cls.OBJ_VAL());
		return true;
	}

	public static function class_name(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, args.value(0).AS_CLASS().name.OBJ_VAL());
		return true;
	}

	public static function class_supertype(vm:VM, args:ValuePointer):Bool {
		var classObj = args.value(0).AS_CLASS();
		// Object has no superclass.
		if (classObj.superClass == null) {
			args.setValue(0, Value.NULL_VAL());
		}
		args.setValue(0, classObj.superClass.OBJ_VAL());
		return true;
	}

	public static function class_toString(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, args.value(0).AS_CLASS().name.OBJ_VAL());
		return true;
	}

	public static function bool_toString(vm:VM, args:ValuePointer):Bool {
		if (args.value(0).AS_BOOL()) {
			args.setValue(0, ObjString.CONST_STRING(vm, "true"));
			return true;
		} else {
			args.setValue(0, ObjString.CONST_STRING(vm, "false"));
			return true;
		}
	}

	public static function bool_not(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_BOOL()));
		return true;
	}

	public static function fiber_new(vm:VM, args:ValuePointer):Bool {
		if (!validateFn(vm, args.value(1), "Argument"))
			return false;
		var closure = args.value(1).AS_CLOSURE();
		if (closure.arity > 1) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Function cannot take more than one parameter.");
			return false;
		}
		args.setValue(0, (new ObjFiber(vm, closure)).OBJ_VAL());
		return false;
	}

	public static function fiber_abort(vm:VM, args:ValuePointer):Bool {
		vm.fiber.error = args.value(1);
		// If the error is explicitly null, it's not really an abort.
		return args.value(1).IS_NULL();
	}

	/**
	 * Transfer execution to [fiber] coming from the current fiber whose stack has
	 * [args].
	 *
	 * [isCall] is true if [fiber] is being called and not transferred.
	 *
	 * [hasValue] is true if a value in [args] is being passed to the new fiber.
	 * Otherwise, `null` is implicitly being passed.
	 * @param vm
	 * @param fiber
	 * @param args
	 * @param isCall
	 * @param hasValue
	 * @param verb
	 */
	public static function runFiber(vm:VM, fiber:ObjFiber, args:ValuePointer, isCall:Bool, hasValue:Bool, verb:String):Bool {
		return false;
	}

	public static function fiber_call(vm:VM, args:ValuePointer):Bool {
		return runFiber(vm, args.value(0).AS_FIBER(), args, true, false, "call");
	}

	public static function fiber_call1(vm:VM, args:ValuePointer):Bool {
		return runFiber(vm, args.value(0).AS_FIBER(), args, true, true, "call");
	}

	public static function fiber_current(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, vm.fiber.OBJ_VAL());
		return true;
	}

	public static function fiber_error(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, args.value(0).AS_FIBER().error);
		return true;
	}

	public static function fiber_isDone(vm:VM, args:ValuePointer):Bool {
		var runFiber = args.value(0).AS_FIBER();
		args.setValue(0, Value.BOOL_VAL(runFiber.numFrames == 0 || runFiber.hasError()));
		return true;
	}

	public static function fiber_suspend(vm:VM, args:ValuePointer):Bool {
		// Switching to a null fiber tells the interpreter to stop and exit.
		vm.fiber = null;
		vm.apiStack = null;
		return false;
	}

	public static function fiber_transfer(vm:VM, args:ValuePointer):Bool {
		return runFiber(vm, args.value(0).AS_FIBER(), args, false, false, "transfer to");
	}

	public static function fiber_transfer1(vm:VM, args:ValuePointer):Bool {
		return runFiber(vm, args.value(0).AS_FIBER(), args, false, true, "transfer to");
	}

	public static function fiber_transferError(vm:VM, args:ValuePointer):Bool {
		runFiber(vm, args.value(0).AS_FIBER(), args, false, true, "transfer to");
		vm.fiber.error = args.value(1);
		return false;
	}

	public static function fiber_try(vm:VM, args:ValuePointer):Bool {
		runFiber(vm, args.value(0).AS_FIBER(), args, true, false, "try");
		// If we're switching to a valid fiber to try, remember that we're trying it.
		if (!vm.fiber.hasError())
			vm.fiber.state = FIBER_TRY;
		return false;
	}

	public static function fiber_yield(vm:VM, args:ValuePointer):Bool {
		var current = vm.fiber;
		vm.fiber = current.caller;

		// Unhook this fiber from the one that called it.
		current.caller = null;
		current.state = FIBER_OTHER;

		if (vm.fiber != null) {
			// Make the caller's run method return null.
			vm.fiber.stackTop.setValue(-1, Value.NULL_VAL());
		}

		return false;
	}

	public static function fiber_yield1(vm:VM, args:ValuePointer):Bool {
		var current = vm.fiber;
		vm.fiber = current.caller;

		// Unhook this fiber from the one that called it.
		current.caller = null;
		current.state = FIBER_OTHER;

		if (vm.fiber != null) {
			// Make the caller's run method return null.
			vm.fiber.stackTop.setValue(-1, args.value(1));

			// When the yielding fiber resumes, we'll store the result of the yield
			// call in its stack. Since Fiber.yield(value) has two arguments (the Fiber
			// class and the value) and we only need one slot for the result, discard
			// the other slot now.
			current.stackTop.dec();
		}

		return false;
	}

	public static function fn_new(vm:VM, args:ValuePointer):Bool {
		if (!validateFn(vm, args.value(1), "Argument"))
			return false;
		// The block argument is already a function, so just return it.
		args.setValue(0, args.value(1));
		return true;
	}

	public static function fn_arity(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_CLOSURE().arity));
		return true;
	}

	public static function call_fn(vm:VM, args:ValuePointer, numArgs:Int):Void {
		// We only care about missing arguments, not extras.
		if (args.value(0).AS_CLOSURE().arity > numArgs) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Function expects more arguments.");
			return;
		}
		// +1 to include the function itself.
		vm.fiber.callFunction(vm, args.value(0).AS_CLOSURE(), numArgs);
	}

	public static function fn_call0(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 0);
		return false;
	}

	public static function fn_call1(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 1);
		return false;
	}

	public static function fn_call2(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 2);
		return false;
	}

	public static function fn_call3(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 3);
		return false;
	}

	public static function fn_call4(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 4);
		return false;
	}

	public static function fn_call5(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 5);
		return false;
	}

	public static function fn_call6(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 6);
		return false;
	}

	public static function fn_call7(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 7);
		return false;
	}

	public static function fn_call8(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 8);
		return false;
	}

	public static function fn_call9(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 9);
		return false;
	}

	public static function fn_call10(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 10);
		return false;
	}

	public static function fn_call11(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 11);
		return false;
	}

	public static function fn_call12(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 12);
		return false;
	}

	public static function fn_call13(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 13);
		return false;
	}

	public static function fn_call14(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 14);
		return false;
	}

	public static function fn_call15(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 15);
		return false;
	}

	public static function fn_call16(vm:VM, args:ValuePointer):Bool {
		call_fn(vm, args, 16);
		return false;
	}

	public static function fn_toString(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, ObjString.CONST_STRING(vm, "<fn>"));
		return true;
	}

	public static function null_not(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(true));
		return true;
	}

	public static function null_toString(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, ObjString.CONST_STRING(vm, "null"));
		return true;
	}

	public static function num_fromString(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Argument"))
			return false;
		var string = args.value(1).AS_STRING();
		// Corner case: Can't parse an empty string.
		if (string.length == 0) {
			args.setValue(0, Value.NULL_VAL());
			return true;
		}

		try {
			args.setValue(0, Value.NUM_VAL(Std.parseFloat(string.value.join(""))));
			return true;
		} catch (e:haxe.Exception) {
			vm.fiber.error = ObjString.CONST_STRING(vm, 'Problem converting number to string:\n ${e.message}');
			return false;
		}
	}

	public static function num_pi(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(3.14159265358979323846));
		return true;
	}

	public static function num_minus(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_NUM() - args.value(1).AS_NUM()));
		return true;
	}

	public static function num_plus(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_NUM() + args.value(1).AS_NUM()));
		return true;
	}

	public static function num_multiply(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_NUM() * args.value(1).AS_NUM()));
		return true;
	}

	public static function num_divide(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_NUM() / args.value(1).AS_NUM()));
		return true;
	}

	public static function num_lt(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_NUM() < args.value(1).AS_NUM()));
		return true;
	}

	public static function num_lte(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_NUM() <= args.value(1).AS_NUM()));
		return true;
	}

	public static function num_gt(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_NUM() > args.value(1).AS_NUM()));
		return true;
	}

	public static function num_gte(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_NUM() >= args.value(1).AS_NUM()));
		return true;
	}

	public static function num_bitwiseAnd(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(Std.int(args.value(0).AS_NUM()) & Std.int(args.value(1).AS_NUM())));
		return true;
	}

	public static function num_bitwiseOr(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(Std.int(args.value(0).AS_NUM()) | Std.int(args.value(1).AS_NUM())));
		return true;
	}

	public static function num_bitwiseXor(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(Std.int(args.value(0).AS_NUM()) ^ Std.int(args.value(1).AS_NUM())));
		return true;
	}

	public static function num_bitwiseLeftShift(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(Std.int(args.value(0).AS_NUM()) << Std.int(args.value(1).AS_NUM())));
		return true;
	}

	public static function num_bitwiseRightShift(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(Std.int(args.value(0).AS_NUM()) >> Std.int(args.value(1).AS_NUM())));
		return true;
	}

	public static function num_negate(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(-args.value(0).AS_NUM()));
		return true;
	}

	static function num_func(vm:VM, args:ValuePointer, mathFunc:Function):Bool {
		args.setValue(0, Value.NUM_VAL(mathFunc(args.value(0).AS_NUM())));
		return true;
	}

	static function num_func2(vm:VM, args:ValuePointer, mathFunc:Function):Bool {
		args.setValue(0, Value.NUM_VAL(mathFunc(args.value(0).AS_NUM(), args.value(1).AS_NUM())));
		return true;
	}

	public static function num_abs(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.abs);
	}

	public static function num_acos(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.acos);
	}

	public static function num_asin(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.asin);
	}

	public static function num_atan(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.atan);
	}

	public static function num_atan2(vm:VM, args:ValuePointer):Bool {
		return num_func2(vm, args, Math.atan2);
	}

	public static function num_pow(vm:VM, args:ValuePointer):Bool {
		return num_func2(vm, args, Math.pow);
	}

	public static function num_ceil(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.ceil);
	}

	public static function num_cos(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.cos);
	}

	public static function num_sin(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.sin);
	}

	public static function num_floor(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.floor);
	}

	public static function num_round(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.round);
	}

	public static function num_sqrt(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.sqrt);
	}

	public static function num_tan(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.tan);
	}

	public static function num_log(vm:VM, args:ValuePointer):Bool {
		return num_func(vm, args, Math.log);
	}

	public static function num_mod(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_NUM() % args.value(1).AS_NUM()));
		return true;
	}

	public static function num_fraction(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_NUM() % 1));
		return true;
	}

	public static function num_eqeq(vm:VM, args:ValuePointer):Bool {
		if (!args.value(1).IS_NUM()) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_NUM() == args.value(1).AS_NUM()));
		return true;
	}

	public static function num_bangeq(vm:VM, args:ValuePointer):Bool {
		if (!args.value(1).IS_NUM()) {
			args.setValue(0, Value.BOOL_VAL(true));
			return true;
		}
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_NUM() == args.value(1).AS_NUM()));
		return true;
	}

	public static function num_bitwiseNot(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(~Std.int(args.value(0).AS_NUM())));
		return true;
	}

	public static function num_dotDot(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right hand side of range"))
			return false;
		var from = args.value(0).AS_NUM();
		var to = args.value(1).AS_NUM();
		// RETURN_VAL(wrenNewRange(vm, from, to, true));
		args.setValue(0, (new ObjRange(vm, from, to, true)).OBJ_VAL());
		return true;
	}

	public static function num_dotDotDot(vm:VM, args:ValuePointer):Bool {
		if (!validateNum(vm, args.value(1), "Right hand side of range"))
			return false;
		var from = args.value(0).AS_NUM();
		var to = args.value(1).AS_NUM();
		args.setValue(0, (new ObjRange(vm, from, to, false)).OBJ_VAL());
		return true;
	}

	public static function num_isInfinity(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(!Math.isFinite(args.value(0).AS_NUM())));
		return true;
	}

	public static function num_isNan(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(!Math.isNaN(args.value(0).AS_NUM())));
		return true;
	}

	public static function num_isInteger(vm:VM, args:ValuePointer):Bool {
		var value = args.value(0).AS_NUM();
		if (Math.isNaN(value) || !Math.isFinite(value)) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}
		args.setValue(0, Value.BOOL_VAL(num_trunc(value) == value));
		return true;
	}

	public static function num_truncate(vm:VM, args:ValuePointer):Bool {
		var value = args.value(0).AS_NUM();
		args.setValue(0, Value.NUM_VAL(num_trunc(value)));
		return true;
	}

	public static function num_largest(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(1.79769e+308));
		return true;
	}

	public static function num_smallest(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(-1.79769e+308));
		return true;
	}

	public static function num_toString(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, ObjString.newString(vm, Std.string(args.value(0).AS_NUM())));
		return true;
	}

	public static function num_sign(vm:VM, args:ValuePointer):Bool {
		var value = args.value(0).AS_NUM();
		if (value > 0) {
			args.setValue(0, Value.NUM_VAL(1));
			return true;
		} else if (value < 0) {
			args.setValue(0, Value.NUM_VAL(-1));
			return true;
		} else {
			args.setValue(0, Value.NUM_VAL(0));
			return true;
		}
	}

	public static function string_fromCodePoint(vm:VM, args:ValuePointer):Bool {
		if (!validateInt(vm, args.value(1), "Code point"))
			return false;
		var codePoint = Std.int(args.value(1).AS_NUM());
		if (codePoint < 0) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Code point cannot be negative.");
			return false;
		} else if (codePoint > 0x10ffff) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Code point cannot be greater than 0x10ffff.");
			return false;
		}

		args.setValue(0, ObjString.fromCodePoint(vm, codePoint));
		return true;
	}

	public static function string_fromByte(vm:VM, args:ValuePointer):Bool {
		if (!validateInt(vm, args.value(1), "Byte"))
			return false;
		var byte = Std.int(args.value(1).AS_NUM());
		if (byte < 0) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Byte cannot be negative.");
			return false;
		} else if (byte > 0xff) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Byte cannot be greater than 0xff.");
			return false;
		}
		args.setValue(0, ObjString.fromByte(vm, byte));
		return true;
	}

	public static function string_byteAt(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();
		var buf = new BytesOutput();
		buf.writeString(string.value.join(""));

		var index = validateIndex(vm, args.value(1), string.length, "Index");
		if (index == 0xFFFFFFFF)
			return false;

		args.setValue(0, Value.NUM_VAL(buf.getBytes().get(index)));
		return true;
	}

	public static function string_byteCount(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();
		args.setValue(0, Value.NUM_VAL(string.length));
		return true;
	}

	public static function string_codePointAt(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();
		var index = validateIndex(vm, args.value(1), string.length, "Index");
		if (index == 0xFFFFFFFF)
			return false;

		args.setValue(0, Value.NUM_VAL(string.value[index].charCodeAt(0)));
		return true;
	}

	public static function string_contains(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Argument"))
			return false;
		var string = args.value(0).AS_STRING();
		var search = args.value(1).AS_STRING();

		args.setValue(0, Value.BOOL_VAL(ObjString.find(vm, string, search)));
		return true;
	}

	public static function string_endsWith(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Argument"))
			return false;
		var string = args.value(0).AS_STRING();
		var search = args.value(1).AS_STRING();

		// Edge case: If the search string is longer then return false right away.
		if (search.length > string.length) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}
		args.setValue(0, Value.BOOL_VAL(StringTools.endsWith(string.value.join(""), search.value.join(""))));
		return true;
	}

	public static function string_indexOf1(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Argument"))
			return false;
		var string = args.value(0).AS_STRING();
		var search = args.value(1).AS_STRING();

		var index = string.value.join("").indexOf(search.value.join(""));
		args.setValue(0, Value.NUM_VAL(index));
		return true;
	}

	public static function string_indexOf2(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Argument"))
			return false;
		var string = args.value(0).AS_STRING();
		var search = args.value(1).AS_STRING();
		var start = validateIndex(vm, args.value(2), string.length, "Start");
		if (start == 0xFFFFFFFF)
			return false;

		var index = string.value.join("").indexOf(search.value.join(""), start);
		args.setValue(0, Value.NUM_VAL(index));
		return true;
	}

	public static function string_iterate(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();

		// If we're starting the iteration, return the first index.
		if (args.value(1).IS_NULL()) {
			if (string.length == 0) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
			args.setValue(0, Value.NUM_VAL(0));
			return true;
		}

		if (!validateInt(vm, args.value(1), "Iterator"))
			return false;
		if (args.value(1).AS_NUM() < 0) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		var index = Std.int(args.value(1).AS_NUM());

		// Advance to the beginning of the next UTF-8 sequence.
		do {
			index++;
			if (index >= string.length) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
		} while ((string.value[index].charCodeAt(0) & 0xc0) == 0x80);

		args.setValue(0, Value.NUM_VAL(index));
		return true;
	}

	public static function string_iterateByte(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();

		// If we're starting the iteration, return the first index.
		if (args.value(1).IS_NULL()) {
			if (string.length == 0) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
			args.setValue(0, Value.NUM_VAL(0));
			return true;
		}

		if (!validateInt(vm, args.value(1), "Iterator"))
			return false;
		if (args.value(1).AS_NUM() < 0) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		var index = Std.int(args.value(1).AS_NUM());

		// Advance to the next byte.
		index++;
		if (index >= string.length) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		args.setValue(0, Value.NUM_VAL(index));
		return true;
	}

	public static function string_iteratorValue(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();
		var index = validateIndex(vm, args.value(1), string.length, "Iterator");
		if (index == 0xFFFFFFFF)
			return false;

		args.setValue(0, ObjString.codePointAt(vm, string, index));
		return true;
	}

	public static function string_startsWith(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Argument"))
			return false;
		var string = args.value(0).AS_STRING();
		var search = args.value(1).AS_STRING();

		// Edge case: If the search string is longer then return false right away.
		if (search.length > string.length) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		args.setValue(0, Value.BOOL_VAL(StringTools.startsWith(string.value.join(""), search.value.join(""))));
		return true;
	}

	public static function string_plus(vm:VM, args:ValuePointer):Bool {
		if (!validateString(vm, args.value(1), "Right operand"))
			return false;
		args.setValue(0, ObjString.format(vm, "@@", [args.value(0), args.value(1)]));
		return true;
	}

	public static function string_subscript(vm:VM, args:ValuePointer):Bool {
		var string = args.value(0).AS_STRING();

		if (args.value(1).IS_NULL()) {
			var index = validateIndex(vm, args.value(1), string.length, "Subscript");
			if (index == -1)
				return false;

			args.setValue(0, ObjString.codePointAt(vm, string, index));
			return true;
		}

		if (!args.value(1).IS_RANGE()) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Subscript must be a number or a range.");
		}

		var step:Int = 0;
		var count = string.length;
		var start = calculateRange(vm, args.value(1).AS_RANGE(), count, step);
		if (start == -1)
			return false;

		args.setValue(0, ObjString.fromRange(vm, string, start, count, step));
		return true;
	}

	public static function string_toString(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, args.value(0));
		return true;
	}

	// Creates a new list of size args[1], with all elements initialized to args[2].
	public static function list_filled(vm:VM, args:ValuePointer):Bool {
		if (!validateInt(vm, args.value(1), "Size"))
			return false;
		if (args.value(1).AS_NUM() < 0) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Size cannot be negative.");
			return false;
		}
		var size = Std.int(args.value(1).AS_NUM());
		var list = new ObjList(vm, size);

		for (i in 0...size) {
			list.elements.data[i] = args.value(2);
		}

		args.setValue(0, list.OBJ_VAL());
		return true;
	}

	public static function list_new(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, (new ObjList(vm, 0)).OBJ_VAL());
		return true;
	}

	public static function list_add(vm:VM, args:ValuePointer):Bool {
		args.value(0).AS_LIST().elements.write(args.value(1));
		args.setValue(0, args.value(1));
		return true;
	}

	/**
	 * Adds an element to the list and then returns the list itself. This is called
	 * by the compiler when compiling list literals instead of using add() to
	 * minimize stack churn.
	 * @param vm
	 * @param args
	 * @return Bool
	 */
	public static function list_addCore(vm:VM, args:ValuePointer):Bool {
		args.value(0).AS_LIST().elements.write(args.value(1));

		// Return the list.
		args.setValue(0, args.value(0));
		return true;
	}

	public static function list_clear(vm:VM, args:ValuePointer):Bool {
		args.value(0).AS_LIST().elements.clear();
		args.setValue(0, Value.NULL_VAL());
		return true;
	}

	public static function list_count(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_LIST().elements.count));
		return true;
	}

	public static function list_insert(vm:VM, args:ValuePointer):Bool {
		var list = args.value(0).AS_LIST();

		// count + 1 here so you can "insert" at the very end.
		var index = validateIndex(vm, args.value(1), list.elements.count + 1, "Index");
		if (index == 0xFFFFFFFF)
			return false;

		list.insert(vm, args.value(2), index);
		args.setValue(0, args.value(2));
		return true;
	}

	public static function list_iterate(vm:VM, args:ValuePointer):Bool {
		var list = args.value(0).AS_LIST();

		// If we're starting the iteration, return the first index.
		if (args.value(1).IS_NULL()) {
			if (list.elements.count == 0) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
			args.setValue(0, Value.NUM_VAL(0));
			return true;
		}
		if (!validateInt(vm, args.value(1), "Iterator"))
			return false;

		// Stop if we're out of bounds.
		var index = args.value(1).AS_NUM();
		if (index < 0 || index >= list.elements.count - 1) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}
		// Otherwise, move to the next index.
		args.setValue(0, Value.NUM_VAL(index + 1));
		return true;
	}

	public static function list_iteratorValue(vm:VM, args:ValuePointer):Bool {
		var list = args.value(0).AS_LIST();
		var index = validateIndex(vm, args.value(1), list.elements.count, "Iterator");

		if (index == 0xFFFFFFFF)
			return false;

		args.setValue(0, list.elements.data[index]);
		return true;
	}

	public static function list_removeAt(vm:VM, args:ValuePointer):Bool {
		var list = args.value(0).AS_LIST();
		var index = validateIndex(vm, args.value(1), list.elements.count, "Index");

		if (index == 0xFFFFFFFF)
			return false;

		args.setValue(0, list.removeAt(vm, index));
		return true;
	}

	public static function list_subscript(vm:VM, args:ValuePointer):Bool {
		var list = args.value(0).AS_LIST();
		if (args.value(1).IS_NUM()) {
			var index = validateIndex(vm, args.value(1), list.elements.count, "Subscript");

			if (index == 0xFFFFFFFF)
				return false;

			args.setValue(0, list.elements.data[index]);
			return true;
		}

		if (!args.value(1).IS_RANGE()) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Subscript must be a number or a range.");
		}

		var step:Int = 0;
		var count = list.elements.count;
		var start = calculateRange(vm, args.value(1).AS_RANGE(), count, step);
		if (start == 0xFFFFFFFF)
			return false;

		var result = new ObjList(vm, count);

		for (i in 0...count) {
			result.elements.data[i] = list.elements.data[start + i * step];
		}

		args.setValue(0, result.OBJ_VAL());
		return true;
	}

	public static function list_subscriptSetter(vm:VM, args:ValuePointer):Bool {
		var list = args.value(0).AS_LIST();
		var index = validateIndex(vm, args.value(1), list.elements.count, "Subscript");

		if (index == 0xFFFFFFFF)
			return false;

		list.elements.data[index] = args.value(2);

		args.setValue(0, args.value(2));
		return true;
	}

	public static function map_new(vm:VM, args:ValuePointer):Bool {
		var map = new ObjMap(vm);
		args.setValue(0, map.OBJ_VAL());
		return true;
	}

	public static function map_subscript(vm:VM, args:ValuePointer):Bool {
		if (!validateKey(vm, args.value(1)))
			return false;
		var map = args.value(0).AS_MAP();

		var value = map.get(vm, args.value(1));
		if (value.IS_UNDEFINED()) {
			args.setValue(0, Value.NULL_VAL());
			return true;
		}

		args.setValue(0, value);
		return true;
	}

	public static function map_subscriptSetter(vm:VM, args:ValuePointer):Bool {
		if (!validateKey(vm, args.value(1)))
			return false;
		var map = args.value(0).AS_MAP();
		map.set(vm, args.value(1), args.value(2));
		args.setValue(0, args.value(2));
		return true;
	}

	/**
	 * Adds an entry to the map and then returns the map itself. This is called by
	 * the compiler when compiling map literals instead of using [_]=(_) to
	 * minimize stack churn.
	 * @param vm
	 * @param args
	 * @return Bool
	 */
	public static function map_addCore(vm:VM, args:ValuePointer):Bool {
		if (!validateKey(vm, args.value(1)))
			return false;

		var map = args.value(0).AS_MAP();
		map.set(vm, args.value(1), args.value(2));

		// Return the map itself.
		args.setValue(0, args.value(0));
		return true;
	}

	public static function map_clear(vm:VM, args:ValuePointer):Bool {
		var map = args.value(0).AS_MAP();
		map.clear();
		args.setValue(0, Value.NULL_VAL());
		return true;
	}

	public static function map_containsKey(vm, args:ValuePointer):Bool {
		if (!validateKey(vm, args.value(1)))
			return false;

		var map = args.value(0).AS_MAP();
		var value = map.get(vm, args.value(1));
		args.setValue(0, Value.BOOL_VAL(!value.IS_UNDEFINED()));
		return true;
	}

	public static function map_count(vm:VM, args:ValuePointer):Bool {
		var map = args.value(0).AS_MAP();

		args.setValue(0, Value.NUM_VAL(map.count));
		return true;
	}

	public static function map_remove(vm:VM, args:ValuePointer):Bool {
		if (!validateKey(vm, args.value(1)))
			return false;

		var map = args.value(0).AS_MAP();

		args.setValue(0, map.removeKey(vm, args.value(1)));
		return true;
	}

	public static function map_keyIteratorValue(vm:VM, args:ValuePointer):Bool {
		var map = args.value(0).AS_MAP();
		var index = validateIndex(vm, args.value(1), map.capacity, "Iterator");
		if (index == 0xFFFFFFFF)
			return false;

		var entry = map.entries.value(index);
		if (entry.key.IS_UNDEFINED()) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Invalid map iterator.");
			return false;
		}

		args.setValue(0, entry.key);
		return true;
	}

	public static function map_valueIteratorValue(vm:VM, args:ValuePointer):Bool {
		var map = args.value(0).AS_MAP();
		var index = validateIndex(vm, args.value(1), map.capacity, "Iterator");
		if (index == 0xFFFFFFFF)
			return false;

		var entry = map.entries.value(index);
		if (entry.key.IS_UNDEFINED()) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Invalid map iterator.");
			return false;
		}

		args.setValue(0, entry.value);
		return true;
	}

	public static function map_iterate(vm:VM, args:ValuePointer):Bool {
		var map = args.value(0).AS_MAP();
		if (map.count == 0) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		// If we're starting the iteration, start at the first used entry.
		var index = 0;

		// Otherwise, start one past the last entry we stopped at.
		if (!args.value(1).IS_NULL()) {
			if (!validateInt(vm, args.value(1), "Iterator"))
				return false;
			if (args.value(1).AS_NUM() < 0) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
			index = Std.int(args.value(1).AS_NUM());

			if (index >= map.capacity) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
			// Advance the iterator.
			index++;
		}

		// Find a used entry, if any.
		while (index < map.capacity) {
			if (!map.entries.value(index).key.IS_UNDEFINED()) {
				args.setValue(0, Value.NUM_VAL(index));
				return true;
			}
			index++;
		}

		// If we get here, walked all of the entries.
		args.setValue(0, Value.BOOL_VAL(false));
		return true;
	}

	public static function range_from(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_RANGE().from));
		return true;
	}

	public static function range_to(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.NUM_VAL(args.value(0).AS_RANGE().to));
		return true;
	}

	public static function range_min(vm:VM, args:ValuePointer):Bool {
		var range = args.value(0).AS_RANGE();
		args.setValue(0, Value.NUM_VAL(Math.min(range.from, range.to)));
		return true;
	}

	public static function range_max(vm:VM, args:ValuePointer):Bool {
		var range = args.value(0).AS_RANGE();
		args.setValue(0, Value.NUM_VAL(Math.max(range.from, range.to)));
		return true;
	}

	public static function range_isInclusive(vm:VM, args:ValuePointer):Bool {
		args.setValue(0, Value.BOOL_VAL(args.value(0).AS_RANGE().isInclusive));
		return true;
	}

	public static function range_iterate(vm:VM, args:ValuePointer):Bool {
		var range = args.value(0).AS_RANGE();
		// Special case: empty range.
		if (range.from == range.to && !range.isInclusive) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		// Start the iteration.
		if (args.value(1).IS_NULL()) {
			args.setValue(0, Value.NUM_VAL(range.from));
			return true;
		}

		if (!validateNum(vm, args.value(1), "Iterator"))
			return false;

		var iterator = args.value(1).AS_NUM();

		// Iterate towards [to] from [from].
		if (range.from < range.to) {
			iterator++;
			if (iterator > range.to) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
		} else {
			iterator--;
			if (iterator < range.to) {
				args.setValue(0, Value.BOOL_VAL(false));
				return true;
			}
		}
		if (!range.isInclusive && iterator == range.to) {
			args.setValue(0, Value.BOOL_VAL(false));
			return true;
		}

		args.setValue(0, Value.NUM_VAL(iterator));
		return true;
	}

	public static function range_iteratorValue(vm:VM, args:ValuePointer):Bool {
		// Assume the iterator is a number so that is the value of the range.
		args.setValue(0, args.value(1));
		return true;
	}

	public static function range_toString(vm:VM, args:ValuePointer):Bool {
		var range = args.value(0).AS_RANGE();
		var from = ObjString.numToString(vm, range.from);
		vm.pushRoot(from.AS_OBJ());

		var to = ObjString.numToString(vm, range.to);
		vm.pushRoot(to.AS_OBJ());

		var result = ObjString.format(vm, "@$@", [from, range.isInclusive ? ".." : "...", to]);

		vm.popRoot();
		vm.popRoot();

		args.setValue(0, result);
		return true;
	}

	public static function system_clock(vm:VM, args:ValuePointer):Bool {
		#if sys
		args.setValue(0, Value.NUM_VAL(Sys.time()));
		#elseif js
		args.setValue(0, Value.NUM_VAL(js.lib.Date.now() / 1000));
		#else
		args.setValue(0, Value.NUM_VAL(0));
		#end
		return true;
	}

	public static function system_writeString(vm:VM, args:ValuePointer):Bool {
		if (vm.config.writeFn != null) {
			vm.config.writeFn(vm, args.value(1).AS_CSTRING());
		}
		args.setValue(0, args.value(1));
		return true;
	}

	static function calculateRange(vm:VM, range:ObjRange, length:Int, step:Int):Int {
		step = 0;

		// Edge case: an empty range is allowed at the end of a sequence. This way,
		// list[0..-1] and list[0...list.count] can be used to copy a list even when
		// empty.

		if (range.from == length && range.to == (range.isInclusive ? -1.0 : length)) {
			length = 0;
			return 0;
		}

		var from = validateIndexValue(vm, length, range.from, "Range start");

		if (from == 0xFFFFFFFF)
			return 0xFFFFFFFF;

		// Bounds check the end manually to handle exclusive ranges.
		var value = range.to;

		if (!validateIntValue(vm, value, "Range end"))
			return 0xFFFFFFFF;

		// Negative indices count from the end.
		if (value < 0)
			value = length + value;

		// Convert the exclusive range to an inclusive one.
		if (range.isInclusive) {
			// An exclusive range with the same start and end points is empty.
			if (value == from) {
				length = 0;
				return from;
			}

			// Shift the endpoint to make it inclusive, handling both increasing and
			// decreasing ranges.
			value += value >= from ? -1 : 1;
		}

		// Check bounds.
		if (value < 0 || value >= length) {
			vm.fiber.error = ObjString.CONST_STRING(vm, "Range end out of bounds.");
			return 0xFFFFFFFF;
		}

		var to:Int = Std.int(value);
		length = Std.int(Math.abs(from - to) + 1);
		step = from < to ? 1 : -1;
		return from;
	}

	static function num_trunc(v:Float) {
		return v - (v % 1);
	}

	static function validateFn(vm:VM, arg:Value, argName:String):Bool {
		if (arg.IS_CLOSURE()) {
			return true;
		}
		vm.fiber.error = ObjString.CONST_STRING(vm, '$argName must be a function.');
		return false;
	}

	static function validateNum(vm:VM, arg:Value, argName:String):Bool {
		if (arg.IS_NUM()) {
			return true;
		}
		vm.fiber.error = ObjString.CONST_STRING(vm, '$argName must be a number.');
		return false;
	}

	static function validateIntValue(vm:VM, arg:Float, argName:String):Bool {
		if (num_trunc(arg) == arg) {
			return true;
		}

		vm.fiber.error = ObjString.CONST_STRING(vm, '$argName must be an integer.');
		return false;
	}

	static function validateInt(vm:VM, arg:Value, argName:String):Bool {
		// Make sure it's a number first.
		if (!validateNum(vm, arg, argName)) {
			return false;
		}
		return validateIntValue(vm, arg.AS_NUM(), argName);
	}

	static function validateKey(vm:VM, arg:Value) {
		if (arg.IS_BOOL() || arg.IS_CLASS() || arg.IS_NULL() || arg.IS_NUM() || arg.IS_RANGE() || arg.IS_STRING()) {
			return true;
		}
		vm.fiber.error = ObjString.CONST_STRING(vm, "Key must be a value type.");
		return false;
	}

	static function validateIndex(vm:VM, arg:Value, count:Int, argName:String):Int {
		if (!validateNum(vm, arg, argName))
			return 0xFFFFFFFF;

		return validateIndexValue(vm, count, arg.AS_NUM(), argName);
	}

	static function validateString(vm:VM, arg:Value, argName:String) {
		if (arg.IS_STRING())
			return true;
		vm.fiber.error = ObjString.CONST_STRING(vm, '$argName must be a string.');
		return false;
	}

	static function validateIndexValue(vm:VM, count:Int, value:Float, argName:String) {
		if (!validateIntValue(vm, value, argName))
			return 0xFFFFFFFF;

		// Negative indices count from the end.
		if (value < 0)
			value = count + value;

		// Check bounds.
		if (value >= 0 && value < count)
			return Std.int(value);

		vm.fiber.error = ObjString.CONST_STRING(vm, '$argName out of bounds.');
		return 0xFFFFFFFF;
	}
}
