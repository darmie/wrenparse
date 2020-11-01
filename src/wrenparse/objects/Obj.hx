package wrenparse.objects;

import haxe.ds.Vector;
import wrenparse.VM;

/**
 * Identifies which specific type a heap-allocated object is.
 */
enum ObjType {
	OBJ_CLASS;
	OBJ_CLOSURE;
	OBJ_FIBER;
	OBJ_FN;
	OBJ_FOREIGN;
	OBJ_INSTANCE;
	OBJ_LIST;
	OBJ_MAP;
	OBJ_MODULE;
	OBJ_RANGE;
	OBJ_STRING;
	OBJ_UPVALUE;
}

/**
 * Base class for all heap-allocated objects.
 */
class Obj {
	public var type:ObjType;
	public var isDark:Bool;

	/**
	 * The object's class.
	 */
	public var classObj:ObjClass;

	/**
	 * The next object in the linked list of all currently allocated objects.
	 */
	public var next:Obj;

	public function new(vm:VM, type:ObjType, classObj:ObjClass) {
		this.isDark = false;
		this.next = vm.first;
		this.type = type;
		this.classObj = classObj;
		vm.first = this;
	}

	public function OBJ_VAL() {
		var value = new Value(VAL_OBJ);
		value.as.obj = this;
		return value;
	}

	public function hashObj() {
		return switch type {
			case OBJ_CLASS: return cast(this, ObjClass).name.hashObj();
			case OBJ_FN: {
					var fn = cast(this, ObjFn);
					return Utils.hashNumber(fn.arity) ^ Utils.hashNumber(fn.code.count);
				}
			case OBJ_RANGE: {
					var r = cast(this, ObjRange);
					return Utils.hashNumber(r.from) ^ Utils.hashNumber(r.to);
				}
			case OBJ_STRING: {
					return cast(this, ObjString).hash;
				}
			case _: {
					Utils.ASSERT(false, "Only immutable objects can be hashed.");
					return 0;
				}
		}
	}

	public function dump() {

		return switch (type) {
			case OBJ_CLASS:
				return ('[class ${cast (this, ObjClass).name.value.join("")} $this]');
			case OBJ_CLOSURE:
				return ('[closure ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_FIBER:
				return ('[fiber ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_FN:
				return ('[fn  ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_FOREIGN:
				return ('[foreign ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_INSTANCE:
				return ('[instance ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_LIST:
				return ('[list ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_MAP:
				return ('[map ${Type.getClassName(Type.getClass(this))}]');
			case OBJ_MODULE:
				return ('[module $this]');
			case OBJ_RANGE:
				return ('[range $this]');
			case OBJ_STRING:
				return (cast (this, ObjString).value.join(""));
			case OBJ_UPVALUE:
				return ('[upvalue $this]');
			default:
				return ('[unknown object $type]');
		}
	}
}
