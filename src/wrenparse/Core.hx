package wrenparse;

import wrenparse.objects.*;
import wrenparse.Primitive.PRIMITIVE;

using wrenparse.Primitive;

class Core {
	/**
	 * The core module source
	 */
	public static final coreModuleSource:String = "
	class Bool {}
	class Fiber {}
	class Fn {}
	class Null {}
	class Num {}
	
	class Sequence {
	  all(f) {
		var result = true
		for (element in this) {
		  result = f.call(element)
		  if (!result) return result
		}
		return result
	  }
	
	  any(f) {
		var result = false
		for (element in this) {
		  result = f.call(element)
		  if (result) return result
		}
		return result
	  }
	
	  contains(element) {
		for (item in this) {
		  if (element == item) return true
		}
		return false
	  }
	
	  count {
		var result = 0
		for (element in this) {
		  result = result + 1
		}
		return result
	  }
	
	  count(f) {
		var result = 0
		for (element in this) {
		  if (f.call(element)) result = result + 1
		}
		return result
	  }
	
	  each(f) {
		for (element in this) {
		  f.call(element)
		}
	  }
	
	  isEmpty { iterate(null) ? false : true }
	
	  map(transformation) { MapSequence.new(this, transformation) }
	
	  skip(count) {
		if (!(count is Num) || !count.isInteger || count < 0) {
		  Fiber.abort(\"Count must be a non-negative integer.\")
		}
	
		return SkipSequence.new(this, count)
	  }
	
	  take(count) {
		if (!(count is Num) || !count.isInteger || count < 0) {
		  Fiber.abort(\"Count must be a non-negative integer.\")
		}
	
		return TakeSequence.new(this, count)
	  }
	
	  where(predicate) { WhereSequence.new(this, predicate) }
	
	  reduce(acc, f) {
		for (element in this) {
		  acc = f.call(acc, element)
		}
		return acc
	  }
	
	  reduce(f) {
		var iter = iterate(null)
		if (!iter) Fiber.abort(\"Can't reduce an empty sequence.\")
	
		// Seed with the first element.
		var result = iteratorValue(iter)
		while (iter = iterate(iter)) {
		  result = f.call(result, iteratorValue(iter))
		}
	
		return result
	  }
	
	  join() { join(\"\") }
	
	  join(sep) {
		var first = true
		var result = \"\"
	
		for (element in this) {
		  if (!first) result = result + sep
		  first = false
		  result = result + element.toString
		}
	
		return result
	  }
	
	  toList {
		var result = List.new()
		for (element in this) {
		  result.add(element)
		}
		return result
	  }
	}
	
	class MapSequence is Sequence {
	  construct new(sequence, fn) {
		_sequence = sequence
		_fn = fn
	  }
	
	  iterate(iterator) { _sequence.iterate(iterator) }
	  iteratorValue(iterator) { _fn.call(_sequence.iteratorValue(iterator)) }
	}
	
	class SkipSequence is Sequence {
	  construct new(sequence, count) {
		_sequence = sequence
		_count = count
	  }
	
	  iterate(iterator) {
		if (iterator) {
		  return _sequence.iterate(iterator)
		} else {
		  iterator = _sequence.iterate(iterator)
		  var count = _count
		  while (count > 0 && iterator) {
			iterator = _sequence.iterate(iterator)
			count = count - 1
		  }
		  return iterator
		}
	  }
	
	  iteratorValue(iterator) { _sequence.iteratorValue(iterator) }
	}
	
	class TakeSequence is Sequence {
	  construct new(sequence, count) {
		_sequence = sequence
		_count = count
	  }
	
	  iterate(iterator) {
		if (!iterator) _taken = 1 else _taken = _taken + 1
		return _taken > _count ? null : _sequence.iterate(iterator)
	  }
	
	  iteratorValue(iterator) { _sequence.iteratorValue(iterator) }
	}
	
	class WhereSequence is Sequence {
	  construct new(sequence, fn) {
		_sequence = sequence
		_fn = fn
	  }
	
	  iterate(iterator) {
		while (iterator = _sequence.iterate(iterator)) {
		  if (_fn.call(_sequence.iteratorValue(iterator))) break
		}
		return iterator
	  }
	
	  iteratorValue(iterator) { _sequence.iteratorValue(iterator) }
	}
	
	class String is Sequence {
	  bytes { StringByteSequence.new(this) }
	  codePoints { StringCodePointSequence.new(this) }
	
	  split(delimiter) {
		if (!(delimiter is String) || delimiter.isEmpty) {
		  Fiber.abort(\"Delimiter must be a non-empty string.\")
		}
	
		var result = []
	
		var last = 0
		var index = 0
	
		var delimSize = delimiter.byteCount_
		var size = byteCount_
	
		while (last < size && (index = indexOf(delimiter, last)) != -1) {
		  result.add(this[last...index])
		  last = index + delimSize
		}
	
		if (last < size) {
		  result.add(this[last..-1])
		} else {
		  result.add(\"\")
		}
		return result
	  }
	
	  replace(from, to) {
		if (!(from is String) || from.isEmpty) {
		  Fiber.abort(\"From must be a non-empty string.\")
		} else if (!(to is String)) {
		  Fiber.abort(\"To must be a string.\")
		}
	
		var result = \"\"
	
		var last = 0
		var index = 0
	
		var fromSize = from.byteCount_
		var size = byteCount_
	
		while (last < size && (index = indexOf(from, last)) != -1) {
		  result = result + this[last...index] + to
		  last = index + fromSize
		}
	
		if (last < size) result = result + this[last..-1]
	
		return result
	  }
	
	  trim() { trim_(\"\", true, true) }
	  trim(chars) { trim_(chars, true, true) }
	  trimEnd() { trim_(\"\", false, true) }
	  trimEnd(chars) { trim_(chars, false, true) }
	  trimStart() { trim_(\"\", true, false) }
	  trimStart(chars) { trim_(chars, true, false) }
	
	  trim_(chars, trimStart, trimEnd) {
		if (!(chars is String)) {
		  Fiber.abort(\"Characters must be a string.\")
		}
	
		var codePoints = chars.codePoints.toList
	
		var start
		if (trimStart) {
		  while (start = iterate(start)) {
			if (!codePoints.contains(codePointAt_(start))) break
		  }
	
		  if (start == false) return \"\"
		} else {
		  start = 0
		}
	
		var end
		if (trimEnd) {
		  end = byteCount_ - 1
		  while (end >= start) {
			var codePoint = codePointAt_(end)
			if (codePoint != -1 && !codePoints.contains(codePoint)) break
			end = end - 1
		  }
	
		  if (end < start) return \"\"
		} else {
		  end = -1
		}
	
		return this[start..end]
	  }
	
	  *(count) {
		if (!(count is Num) || !count.isInteger || count < 0) {
		  Fiber.abort(\"Count must be a non-negative integer.\")
		}
	
		var result = \"\"
		for (i in 0...count) {
		  result = result + this
		}
		return result
	  }
	}
	
	class StringByteSequence is Sequence {
	  construct new(string) {
		_string = string
	  }
	
	  [index] { _string.byteAt_(index) }
	  iterate(iterator) { _string.iterateByte_(iterator) }
	  iteratorValue(iterator) { _string.byteAt_(iterator) }
	
	  count { _string.byteCount_ }
	}
	
	class StringCodePointSequence is Sequence {
	  construct new(string) {
		_string = string
	  }
	
	  [index] { _string.codePointAt_(index) }
	  iterate(iterator) { _string.iterate(iterator) }
	  iteratorValue(iterator) { _string.codePointAt_(iterator) }
	
	  count { _string.count }
	}
	
	class List is Sequence {
	  addAll(other) {
		for (element in other) {
		  add(element)
		}
		return other
	  }
	
	  toString { \"[%(join(\", \"))]\" }
	  +(other) {
		var result = this[0..-1]
		for (element in other) {
		  result.add(element)
		}
		return result
	  }
	
	  *(count) {
		if (!(count is Num) || !count.isInteger || count < 0) {
		  Fiber.abort(\"Count must be a non-negative integer.\")
		}
	
		var result = []
		for (i in 0...count) {
		  result.addAll(this)
		}
		return result
	  }
	}
	
	class Map is Sequence {
	  keys { MapKeySequence.new(this) }
	  values { MapValueSequence.new(this) }
	
	  toString {
		var first = true
		var result = \"{\"
	
		for (key in keys) {
		  if (!first) result = result + \", \"
		  first = false
		  result = result + \"%(key): %(this[key])\"
		}
	
		return result + \"}\"
	  }
	
	  iteratorValue(iterator) {
		return MapEntry.new(
			keyIteratorValue_(iterator),
			valueIteratorValue_(iterator))
	  }
	}
	
	class MapEntry {
	  construct new(key, value) {
		_key = key
		_value = value
	  }
	
	  key { _key }
	  value { _value }
	
	  toString { \"%(_key):%(_value)\" }
	}
	
	class MapKeySequence is Sequence {
	  construct new(map) {
		_map = map
	  }
	
	  iterate(n) { _map.iterate(n) }
	  iteratorValue(iterator) { _map.keyIteratorValue_(iterator) }
	}
	
	class MapValueSequence is Sequence {
	  construct new(map) {
		_map = map
	  }
	
	  iterate(n) { _map.iterate(n) }
	  iteratorValue(iterator) { _map.valueIteratorValue_(iterator) }
	}
	
	class Range is Sequence {}
	
	class System {
	  static print() {
		writeString_(\"\")
	  }
	
	  static print(obj) {
		writeObject_(obj)
		writeString_(\"\")
		return obj
	  }
	
	  static printAll(sequence) {
		for (object in sequence) writeObject_(object)
		writeString_(\"\")
	  }
	
	  static write(obj) {
		writeObject_(obj)
		return obj
	  }
	
	  static writeAll(sequence) {
		for (object in sequence) writeObject_(object)
	  }
	
	  static writeObject_(obj) {
		var string = obj.toString
		if (string is String) {
		  writeString_(string)
		} else {
		  writeString_(\"[invalid toString]\")
		}
	  }
	}";
	

	/**
	 * Creates either the Object or Class class in the core module with [name].
	 * @param vm
	 * @param module
	 * @param name
	 */
	private static function defineClass(vm:VM, module:ObjModule, name:String):ObjClass {
		var nameString = ObjString.newString(vm, name).AS_STRING();
		vm.pushRoot(nameString);
		var classObj = new ObjClass(vm, 0, nameString);
		module.defineVariable(vm, name, classObj.OBJ_VAL(), null);
		vm.popRoot();
		return classObj;
	}

	/**
	 * Initialize core modules and primitives
	 * @param vm
	 */
	public static function init(vm:VM) {
		// Sys.println(coreModuleSource);
		var coreModule = new ObjModule(vm, null);
		vm.pushRoot(coreModule);
		// The core module's key is null in the module map.
		vm.modules.set(vm, Value.NULL_VAL(), coreModule.OBJ_VAL());
		vm.popRoot();

		// Define the root Object class. This has to be done a little specially
		// because it has no superclass.
		vm.objectClass = defineClass(vm, coreModule, "Object");
		PRIMITIVE(vm, vm.objectClass, "!", Primitive.object_not);
		PRIMITIVE(vm, vm.objectClass, "==(_)", Primitive.object_eqeq);
		PRIMITIVE(vm, vm.objectClass, "!=(_)", Primitive.object_bangeq);
		PRIMITIVE(vm, vm.objectClass, "is(_)", Primitive.object_is);
		PRIMITIVE(vm, vm.objectClass, "toString", Primitive.object_toString);
		PRIMITIVE(vm, vm.objectClass, "type", Primitive.object_type);

		// Now we can define Class, which is a subclass of Object.
		vm.classClass = defineClass(vm, coreModule, "Class");
		vm.classClass.bindSuperclass(vm, vm.objectClass);
		PRIMITIVE(vm, vm.classClass, "name", Primitive.class_name);
		PRIMITIVE(vm, vm.classClass, "supertype", Primitive.class_supertype);
		PRIMITIVE(vm, vm.classClass, "toString", Primitive.class_toString);

		// Finally, we can define Object's metaclass which is a subclass of Class.
		var objectMetaclass = defineClass(vm, coreModule, "Object metaclass");

		// Wire up the metaclass relationships now that all three classes are built.
		vm.objectClass.classObj = objectMetaclass;
		objectMetaclass.classObj = vm.classClass;
		vm.classClass.classObj = vm.classClass;

		// Do this after wiring up the metaclasses so objectMetaclass doesn't get
		// collected.
		objectMetaclass.bindSuperclass(vm, vm.classClass);

		PRIMITIVE(vm, objectMetaclass, "same(_,_)", Primitive.object_same);
		// The core class diagram ends up looking like this, where single lines point
		// to a class's superclass, and double lines point to its metaclass:
		//
		//        .------------------------------------. .====.
		//        |                  .---------------. | #    #
		//        v                  |               v | v    #
		//   .---------.   .-------------------.   .-------.  #
		//   | Object  |==>| Object metaclass  |==>| Class |=="
		//   '---------'   '-------------------'   '-------'
		//        ^                                 ^ ^ ^ ^
		//        |                  .--------------' # | #
		//        |                  |                # | #
		//   .---------.   .-------------------.      # | # -.
		//   |  Base   |==>|  Base metaclass   |======" | #  |
		//   '---------'   '-------------------'        | #  |
		//        ^                                     | #  |
		//        |                  .------------------' #  | Example classes
		//        |                  |                    #  |
		//   .---------.   .-------------------.          #  |
		//   | Derived |==>| Derived metaclass |=========="  |
		//   '---------'   '-------------------'            -'

		// The rest of the classes can now be defined normally.
		vm.interpret(null, coreModuleSource);

		#if !WREN_DEBUG_DUMP_COMPILED_CODE
		vm.boolClass = coreModule.findVariable(vm, "Bool").AS_CLASS(); // AS_CLASS(wrenFindVariable(vm, coreModule, "Bool"));
		PRIMITIVE(vm, vm.boolClass, "toString", Primitive.bool_toString);
		PRIMITIVE(vm, vm.boolClass, "!", Primitive.bool_not);

		vm.fiberClass = coreModule.findVariable(vm, "Fiber").AS_CLASS();
		PRIMITIVE(vm, vm.fiberClass.classObj, "new(_)", Primitive.fiber_new);
		PRIMITIVE(vm, vm.fiberClass.classObj, "abort(_)", Primitive.fiber_abort);
		PRIMITIVE(vm, vm.fiberClass.classObj, "current", Primitive.fiber_current);
		PRIMITIVE(vm, vm.fiberClass.classObj, "suspend()", Primitive.fiber_suspend);
		PRIMITIVE(vm, vm.fiberClass.classObj, "yield()", Primitive.fiber_yield);
		PRIMITIVE(vm, vm.fiberClass.classObj, "yield(_)", Primitive.fiber_yield1);
		PRIMITIVE(vm, vm.fiberClass, "call()", Primitive.fiber_call);
		PRIMITIVE(vm, vm.fiberClass, "call(_)", Primitive.fiber_call1);
		PRIMITIVE(vm, vm.fiberClass, "error", Primitive.fiber_error);
		PRIMITIVE(vm, vm.fiberClass, "isDone", Primitive.fiber_isDone);
		PRIMITIVE(vm, vm.fiberClass, "transfer()", Primitive.fiber_transfer);
		PRIMITIVE(vm, vm.fiberClass, "transfer(_)", Primitive.fiber_transfer1);
		PRIMITIVE(vm, vm.fiberClass, "transferError(_)", Primitive.fiber_transferError);
		PRIMITIVE(vm, vm.fiberClass, "try()", Primitive.fiber_try);

		vm.fnClass = coreModule.findVariable(vm, "Fn").AS_CLASS();
		PRIMITIVE(vm, vm.fnClass.classObj, "new(_)", Primitive.fn_new);
		PRIMITIVE(vm, vm.fnClass, "arity", Primitive.fn_arity);
		PRIMITIVE(vm, vm.fnClass, "call()", Primitive.fn_call0);
		PRIMITIVE(vm, vm.fnClass, "call(_)", Primitive.fn_call1);
		PRIMITIVE(vm, vm.fnClass, "call(_,_)", Primitive.fn_call2);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_)", Primitive.fn_call3);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_)", Primitive.fn_call4);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_)", Primitive.fn_call5);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_)", Primitive.fn_call6);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_)", Primitive.fn_call7);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_)", Primitive.fn_call8);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_)", Primitive.fn_call9);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call10);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call11);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call12);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call13);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call14);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call15);
		PRIMITIVE(vm, vm.fnClass, "call(_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_)", Primitive.fn_call16);
		PRIMITIVE(vm, vm.fnClass, "toString", Primitive.fn_toString);

		vm.nullClass = coreModule.findVariable(vm, "Null").AS_CLASS();
		PRIMITIVE(vm, vm.nullClass, "!", Primitive.null_not);
		PRIMITIVE(vm, vm.nullClass, "toString", Primitive.null_toString);

		vm.numClass = coreModule.findVariable(vm, "Num").AS_CLASS();
		PRIMITIVE(vm, vm.numClass.classObj, "fromString(_)", Primitive.num_fromString);
		PRIMITIVE(vm, vm.numClass.classObj, "pi", Primitive.num_pi);
		PRIMITIVE(vm, vm.numClass.classObj, "largest", Primitive.num_largest);
		PRIMITIVE(vm, vm.numClass.classObj, "smallest", Primitive.num_smallest);
		PRIMITIVE(vm, vm.numClass, "-(_)", Primitive.num_minus);
		PRIMITIVE(vm, vm.numClass, "+(_)", Primitive.num_plus);
		PRIMITIVE(vm, vm.numClass, "*(_)", Primitive.num_multiply);
		PRIMITIVE(vm, vm.numClass, "/(_)", Primitive.num_divide);
		PRIMITIVE(vm, vm.numClass, "<(_)", Primitive.num_lt);
		PRIMITIVE(vm, vm.numClass, ">(_)", Primitive.num_gt);
		PRIMITIVE(vm, vm.numClass, "<=(_)", Primitive.num_lte);
		PRIMITIVE(vm, vm.numClass, ">=(_)", Primitive.num_gte);
		PRIMITIVE(vm, vm.numClass, "&(_)", Primitive.num_bitwiseAnd);
		PRIMITIVE(vm, vm.numClass, "|(_)", Primitive.num_bitwiseOr);
		PRIMITIVE(vm, vm.numClass, "^(_)", Primitive.num_bitwiseXor);
		PRIMITIVE(vm, vm.numClass, "<<(_)", Primitive.num_bitwiseLeftShift);
		PRIMITIVE(vm, vm.numClass, ">>(_)", Primitive.num_bitwiseRightShift);
		PRIMITIVE(vm, vm.numClass, "abs", Primitive.num_abs);
		PRIMITIVE(vm, vm.numClass, "acos", Primitive.num_acos);
		PRIMITIVE(vm, vm.numClass, "asin", Primitive.num_asin);
		PRIMITIVE(vm, vm.numClass, "atan", Primitive.num_atan);
		PRIMITIVE(vm, vm.numClass, "ceil", Primitive.num_ceil);
		PRIMITIVE(vm, vm.numClass, "cos", Primitive.num_cos);
		PRIMITIVE(vm, vm.numClass, "floor", Primitive.num_floor);
		PRIMITIVE(vm, vm.numClass, "-", Primitive.num_negate);
		PRIMITIVE(vm, vm.numClass, "round", Primitive.num_round);
		PRIMITIVE(vm, vm.numClass, "sin", Primitive.num_sin);
		PRIMITIVE(vm, vm.numClass, "sqrt", Primitive.num_sqrt);
		PRIMITIVE(vm, vm.numClass, "tan", Primitive.num_tan);
		PRIMITIVE(vm, vm.numClass, "log", Primitive.num_log);
		PRIMITIVE(vm, vm.numClass, "%(_)", Primitive.num_mod);
		PRIMITIVE(vm, vm.numClass, "~", Primitive.num_bitwiseNot);
		PRIMITIVE(vm, vm.numClass, "..(_)", Primitive.num_dotDot);
		PRIMITIVE(vm, vm.numClass, "...(_)", Primitive.num_dotDotDot);
		PRIMITIVE(vm, vm.numClass, "atan(_)", Primitive.num_atan2);
		PRIMITIVE(vm, vm.numClass, "pow(_)", Primitive.num_pow);
		PRIMITIVE(vm, vm.numClass, "fraction", Primitive.num_fraction);
		PRIMITIVE(vm, vm.numClass, "isInfinity", Primitive.num_isInfinity);
		PRIMITIVE(vm, vm.numClass, "isInteger", Primitive.num_isInteger);
		PRIMITIVE(vm, vm.numClass, "isNan", Primitive.num_isNan);
		PRIMITIVE(vm, vm.numClass, "sign", Primitive.num_sign);
		PRIMITIVE(vm, vm.numClass, "toString", Primitive.num_toString);
		PRIMITIVE(vm, vm.numClass, "truncate", Primitive.num_truncate);
		// These are defined just so that 0 and -0 are equal, which is specified by
		// IEEE 754 even though they have different bit representations.
		PRIMITIVE(vm, vm.numClass, "==(_)", Primitive.num_eqeq);
		PRIMITIVE(vm, vm.numClass, "!=(_)", Primitive.num_bangeq);

		vm.stringClass = coreModule.findVariable(vm, "String").AS_CLASS();
		PRIMITIVE(vm, vm.stringClass.classObj, "fromCodePoint(_)", Primitive.string_fromCodePoint);
		PRIMITIVE(vm, vm.stringClass.classObj, "fromByte(_)", Primitive.string_fromByte);
		PRIMITIVE(vm, vm.stringClass, "+(_)", Primitive.string_plus);
		PRIMITIVE(vm, vm.stringClass, "[_]", Primitive.string_subscript);
		PRIMITIVE(vm, vm.stringClass, "byteAt_(_)", Primitive.string_byteAt);
		PRIMITIVE(vm, vm.stringClass, "byteCount_", Primitive.string_byteCount);
		PRIMITIVE(vm, vm.stringClass, "codePointAt_(_)", Primitive.string_codePointAt);
		PRIMITIVE(vm, vm.stringClass, "contains(_)", Primitive.string_contains);
		PRIMITIVE(vm, vm.stringClass, "endsWith(_)", Primitive.string_endsWith);
		PRIMITIVE(vm, vm.stringClass, "indexOf(_)", Primitive.string_indexOf1);
		PRIMITIVE(vm, vm.stringClass, "indexOf(_,_)", Primitive.string_indexOf2);
		PRIMITIVE(vm, vm.stringClass, "iterate(_)", Primitive.string_iterate);
		PRIMITIVE(vm, vm.stringClass, "iterateByte_(_)", Primitive.string_iterateByte);
		PRIMITIVE(vm, vm.stringClass, "iteratorValue(_)", Primitive.string_iteratorValue);
		PRIMITIVE(vm, vm.stringClass, "startsWith(_)", Primitive.string_startsWith);
		PRIMITIVE(vm, vm.stringClass, "toString", Primitive.string_toString);


		vm.listClass = coreModule.findVariable(vm, "List").AS_CLASS();
		PRIMITIVE(vm, vm.listClass.classObj, "filled(_,_)", Primitive.list_filled);
		PRIMITIVE(vm, vm.listClass.classObj, "new()", Primitive.list_new);
		PRIMITIVE(vm, vm.listClass, "[_]", Primitive.list_subscript);
		PRIMITIVE(vm, vm.listClass, "[_]=(_)", Primitive.list_subscriptSetter);
		PRIMITIVE(vm, vm.listClass, "add(_)", Primitive.list_add);
		PRIMITIVE(vm, vm.listClass, "addCore_(_)", Primitive.list_addCore);
		PRIMITIVE(vm, vm.listClass, "clear()", Primitive.list_clear);
		PRIMITIVE(vm, vm.listClass, "count", Primitive.list_count);
		PRIMITIVE(vm, vm.listClass, "insert(_,_)", Primitive.list_insert);
		PRIMITIVE(vm, vm.listClass, "iterate(_)", Primitive.list_iterate);
		PRIMITIVE(vm, vm.listClass, "iteratorValue(_)", Primitive.list_iteratorValue);
		PRIMITIVE(vm, vm.listClass, "removeAt(_)", Primitive.list_removeAt);

		vm.mapClass = coreModule.findVariable(vm, "Map").AS_CLASS();
		PRIMITIVE(vm, vm.mapClass.classObj, "new()", Primitive.map_new);
		PRIMITIVE(vm, vm.mapClass, "[_]", Primitive.map_subscript);
		PRIMITIVE(vm, vm.mapClass, "[_]=(_)", Primitive.map_subscriptSetter);
		PRIMITIVE(vm, vm.mapClass, "addCore_(_,_)", Primitive.map_addCore);
		PRIMITIVE(vm, vm.mapClass, "clear()", Primitive.map_clear);
		PRIMITIVE(vm, vm.mapClass, "containsKey(_)", Primitive.map_containsKey);
		PRIMITIVE(vm, vm.mapClass, "count", Primitive.map_count);
		PRIMITIVE(vm, vm.mapClass, "remove(_)", Primitive.map_remove);
		PRIMITIVE(vm, vm.mapClass, "iterate(_)", Primitive.map_iterate);
		PRIMITIVE(vm, vm.mapClass, "keyIteratorValue_(_)", Primitive.map_keyIteratorValue);
		PRIMITIVE(vm, vm.mapClass, "valueIteratorValue_(_)", Primitive.map_valueIteratorValue);


		vm.rangeClass = coreModule.findVariable(vm, "Range").AS_CLASS();
		PRIMITIVE(vm, vm.rangeClass, "from", Primitive.range_from);
		PRIMITIVE(vm, vm.rangeClass, "to", Primitive.range_to);
		PRIMITIVE(vm, vm.rangeClass, "min", Primitive.range_min);
		PRIMITIVE(vm, vm.rangeClass, "max", Primitive.range_max);
		PRIMITIVE(vm, vm.rangeClass, "isInclusive", Primitive.range_isInclusive);
		PRIMITIVE(vm, vm.rangeClass, "iterate(_)", Primitive.range_iterate);
		PRIMITIVE(vm, vm.rangeClass, "iteratorValue(_)", Primitive.range_iteratorValue);
		PRIMITIVE(vm, vm.rangeClass, "toString", Primitive.range_toString);

		var systemClass = coreModule.findVariable(vm, "System").AS_CLASS();
		PRIMITIVE(vm, systemClass.classObj, "clock", Primitive.system_clock);
		// PRIMITIVE(vm, systemClass.classObj, "gc()", Primitive.system_gc);
		PRIMITIVE(vm, systemClass.classObj, "writeString_(_)", Primitive.system_writeString);

		// While bootstrapping the core types and running the core module, a number
		// of string objects have been created, many of which were instantiated
		// before stringClass was stored in the VM. Some of them *must* be created
		// first -- the ObjClass for string itself has a reference to the ObjString
		// for its name.
		//
		// These all currently have a NULL classObj pointer, so go back and assign
		// them now that the string class is known.
		var obj = vm.first;
		while(obj != null){
			if (obj.type == OBJ_STRING) obj.classObj = vm.stringClass;
			obj = obj.next;
		}
		#end
	}
}
