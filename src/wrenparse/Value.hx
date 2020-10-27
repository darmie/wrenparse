package wrenparse;


import haxe.ds.Vector;
import haxe.Int64;
import wrenparse.objects.*;
import wrenparse.IO.Buffer;
import polygonal.ds.ArrayList;

enum ValueType {
	VAL_FALSE;
	VAL_NULL;
	VAL_NUM;
	VAL_TRUE;
	VAL_UNDEFINED;
	VAL_OBJ;
}

typedef ValueBuffer = Buffer<Value>;

class ValuePointer {
	public var arr:ArrayList<Value>;
	public var index: Int;

	public function new(arr:ArrayList<Value>, index: Int = 0) {
		this.arr = arr;
		this.index = index;
	}

	public inline function value(index: Int = 0): Value {
		return arr.get(this.index + index);
	}

	public inline function setValue(index: Int, value: Value): Void {
		arr.insert(this.index + index, value);
	}

	public inline function resize(size:Int) {
		this.arr.resize(size);
	}

	public inline function inc(): Void {
		++index;
	}

	public inline function dec(): Value {
		--index;
		return value();
	}

	public inline function drop(): Value {
		index--;
		return value();
	}

	public inline function pointer(index: Int): ValuePointer {
		return new ValuePointer(arr, this.index + index);
	}

	public inline function sub(pointer: ValuePointer): Int {
		return index - pointer.index;
	}

	public inline function lt(pointer: ValuePointer): Bool {
		return index < pointer.index;
	}

	public inline function gt(pointer: ValuePointer): Bool {
		return index > pointer.index;
	}

	public inline function gte(pointer: ValuePointer): Bool {
		return index >= pointer.index;
	}

	public inline function lte(pointer: ValuePointer): Bool {
		return index <= pointer.index;
	}
}

typedef ValueAs = {
	?num:Float,
	?obj:Obj
}

class Value {
	public var type:ValueType;
	public var as:ValueAs; // num or object

	public function new(type:ValueType) {
		this.type = type;
		this.as = {};
	}

	public inline function AS_OBJ() {
		return this.as.obj;
	}

	public inline function AS_RANGE():ObjRange {
		return cast this.as.obj;
	}

	public inline function AS_FIBER():ObjFiber {
		return cast this.as.obj;
	}

	public inline function AS_STRING():ObjString {
		return cast this.as.obj;
	}

	public inline function AS_CSTRING():String {
		var v = cast(this.as.obj, ObjString).value;
		if(v == null) return null;
		return v.join("");
	}

	public inline function AS_NUM():Float {
		return cast this.as.num;
	}

	public inline function IS_OBJ() {
		return this.type == VAL_OBJ;
	}

	public inline function IS_INSTANCE() {
		return this.type == VAL_OBJ && this.AS_OBJ().type == OBJ_INSTANCE;
	}

	public inline function IS_CLOSURE() {
		return this.type == VAL_OBJ && this.AS_OBJ().type == OBJ_CLOSURE;
	}

	public inline function AS_CLOSURE() {
		var obj:ObjClosure = cast this.AS_OBJ();
		return obj;
	}



	public inline function AS_INSTANCE() {
		var obj:ObjInstance = cast this.AS_OBJ();
		return obj;
	}

	public inline function AS_CLASS() {
		var obj:ObjClass = cast this.AS_OBJ();
		return obj;
	}

	public inline function IS_FOREIGN() {
		return this.type == VAL_OBJ && this.AS_OBJ().type == OBJ_FOREIGN;
	}

	public inline function AS_FOREIGN() {
		var obj:ObjForeign = cast this.AS_OBJ();
		return obj;
	}

	public inline function AS_FUN():ObjFn {
		return cast this.as.obj;
	}


	public inline function AS_LIST():ObjList {
		return cast this.as.obj;
	}

	public inline function AS_MAP():ObjMap {
		return cast this.as.obj;
	}

	public inline function AS_MODULE():ObjModule {
		return cast this.as.obj;
	}


	public inline function IS_BOOL() return IS_FALSE() || IS_TRUE();
	public inline function IS_FALSE() {
		return this.type == VAL_FALSE;
	}

	public inline function IS_TRUE() {
		return this.type == VAL_TRUE;
	}

	public  inline function AS_BOOL():Bool {
		return IS_TRUE() ? true : false;
	}

	public inline function IS_NUM() {
		return this.type == VAL_NUM;
	}

	public inline function IS_STRING() {
		return this.type == VAL_OBJ && this.as.obj.type == OBJ_STRING;
	}

	public inline function IS_CLASS() {
		return this.type == VAL_OBJ && this.as.obj.type == OBJ_CLASS;
	}

	public inline function IS_UNDEFINED() {
		return this.type == VAL_UNDEFINED;
	}

	public inline function IS_NULL() {
		return this.type == VAL_NULL;
	}

	public inline function IS_LIST() {
		return IS_OBJ() && AS_OBJ().type == OBJ_LIST;
	}

	public inline function IS_RANGE() {
		return IS_OBJ() && AS_OBJ().type == OBJ_RANGE;
	}

	public inline function IS_MAP() {
		return IS_OBJ() && AS_OBJ().type == OBJ_MAP;
	}

	public static inline function NUM_VAL(i:Float) {
		final v = new Value(VAL_NUM);
		v.as.num = i;
		return v;
	}

	public static inline function BOOL_VAL(v:Bool) {
		final v = new Value(v ? VAL_TRUE : VAL_FALSE);
		return v;
	}

	public static inline function NULL_VAL() {
		final v = new Value(VAL_NULL);
		return v;
	}

	public static inline function UNDEFINED_VAL() {
		final v = new Value(VAL_UNDEFINED);
		return v;
	}


	public static function getClass(vm:VM, value:Value) {
		return vm.getClassInline(value);
	}

	public static function same(a:Value, b:Value) {
		if (a.type != b.type)
			return false;
		if (a.type == VAL_NUM)
			return a.as.num == b.as.num;
		return a.as.obj == b.as.obj;
	}

	public static function equal(a:Value, b:Value) {
		if (same(a, b))
			return true;

		// If we get here, it's only possible for two heap-allocated immutable objects
		// to be equal.
		if (!a.IS_OBJ() || !b.IS_OBJ())
			return false;

		var aObj:Obj = a.AS_OBJ();
		var bObj:Obj = b.AS_OBJ();

		// Must be the same type.
		if (aObj.type != bObj.type)
			return false;

		return switch (aObj.type) {
			case OBJ_RANGE:
				{
					var aRange:ObjRange = cast aObj;
					var bRange:ObjRange = cast bObj;
					return aRange.from == bRange.from && aRange.to == bRange.to && aRange.isInclusive == bRange.isInclusive;
				}

			case OBJ_STRING:
				{
					var aString:ObjString = cast aObj;
					var bString:ObjString = cast bObj;
					return aString.hash == bString.hash && aString.value.join("") == bString.value.join("");
				}

			default:
				// All other types are only equal if they are same, which they aren't if
				// we get here.
				return false;
		}
	}

	public function hash():Int64 {
		return switch (type) {
			case VAL_FALSE: return 0;
			case VAL_NULL: return 1;
			case VAL_NUM: return Utils.hashNumber(this.AS_NUM());
			case VAL_TRUE: return 2;
			case VAL_OBJ: return this.AS_OBJ().hashObj();
			default:
				Utils.ASSERT(false, "<unreachable>");
				return 0;
		}
	}

	public function isBool() {
		return this.IS_FALSE() || this.IS_TRUE();
	}

	public function dump() {
		return switch (type) {
			case VAL_FALSE: return "false";
			case VAL_NULL: return "null";
			case VAL_NUM: return '${this.AS_NUM()}';
			case VAL_TRUE: return "true";
			case VAL_OBJ: return this.AS_OBJ().dump();
			case VAL_UNDEFINED: return "<unreachable>";
		}
	}
}
