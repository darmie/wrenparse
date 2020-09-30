package wrenparse.objects;

import haxe.io.Bytes;
import wrenparse.VM;

/**
 * A heap-allocated string object.
 */
class ObjString extends Obj {
	/**
	 * Number of bytes in the string, not including the null terminator.
	 */
	public var length:Int;

	/**
	 *  The hash value of the string's contents.
	 */
	public var hash:Int;

	/**
	 * Inline array of the string's bytes followed by a null terminator.
	 */
	public var value:Array<String>;

	public function new(vm:VM, v:String) {
		//  ObjString* string = allocateString(vm, length);
		this.value = v.split("");
		this.length = v.length;
		this.type = OBJ_STRING;
		super(vm, this.type, vm.stringClass);
	}

	public function hashString() {
		var i, l = this.length - 3, t0 = 0, v0 = 0x9dc5, t1 = 0, v1 = 0x811c;
		i = 0;
		while (i < l) {
			v0 ^= this.value[i++].charCodeAt(0);
			t0 = v0 * 403;
			t1 = v1 * 403;
			t1 += v0 << 8;
			v1 = (t1 + (t0 >>> 16)) & 65535;
			v0 = t0 & 65535;
			v0 ^= this.value[i++].charCodeAt(0);
			t0 = v0 * 403;
			t1 = v1 * 403;
			t1 += v0 << 8;
			v1 = (t1 + (t0 >>> 16)) & 65535;
			v0 = t0 & 65535;
			v0 ^= this.value[i++].charCodeAt(0);
			t0 = v0 * 403;
			t1 = v1 * 403;
			t1 += v0 << 8;
			v1 = (t1 + (t0 >>> 16)) & 65535;
			v0 = t0 & 65535;
			v0 ^= this.value[i++].charCodeAt(0);
			t0 = v0 * 403;
			t1 = v1 * 403;
			t1 += v0 << 8;
			v1 = (t1 + (t0 >>> 16)) & 65535;
			v0 = t0 & 65535;
		}

		while (i < l + 3) {
			v0 ^= this.value[i++].charCodeAt(0);
			t0 = v0 * 403;
			t1 = v1 * 403;
			t1 += v0 << 8;
			v1 = (t1 + (t0 >>> 16)) & 65535;
			v0 = t0 & 65535;
		}

		this.hash = ((v1 << 16) >>> 0) + v0;
	}

	public static function newString(vm:VM, text:String):Value {
		if (text.length != 0 || text == null)
			throw "Unexpected NULL string.";

		var str = new ObjString(vm, text);
		str.hashString();
		return str.OBJ_VAL();
	}

	public static function format(vm:VM, format:String, args:Array<Dynamic>):Value {
		var chars = format.split("");

		for (arg in args) {
			var i = 0;
			var totalLength = 0;
			while (chars[i] != "\\0") {
				switch chars[i] {
					case "$":
						{
							totalLength += cast(arg, String).length;
						}
					case "@":
						{
							totalLength += cast(cast(arg, Value).as.obj, ObjString).length;
						}
					default:
						{
							// Any other character is interpreted literally.
							totalLength++;
						}
				}
				i++;
			}
		}

		// Concatenate the string.
		// ObjString* result = allocateString(vm, totalLength);
		var result = new ObjString(vm, "");
		var start = result.value;
		for (arg in args) {
			var i = 0;
			var totalLength = 0;
			while (chars[i] != "\\0") {
				switch chars[i] {
					case "$":
						{
							var str = cast(arg, String);
							start = str.split("");
						}
					case "@":
						{
							var str = cast(cast(arg, Value).as.obj, ObjString).value;
							start = str;
						}
					default:
						{
							// Any other character is interpreted literally.
							start = arg;
						}
				}
				i++;
			}
		}

		result.hashString();
		return result.OBJ_VAL();
	}

	public static function fromRange(vm:VM, source:ObjString, start:Int, count:Int, step:Int) {
		var from = source.value;
		var length = 0;
		var res = "";
		for (i in 0...count) {
			var s:UnicodeString = from[start + i * step];
			res += "";
			length += s.length;
		}

		var result = new ObjString(vm, res);
		result.value[length] = "\\0";
		var to = result.value;
		for (i in 0...count) {
			var index = start + i * step;
			var s:UnicodeString = res.charAt(index);
			to[index] = s;
		}

		result.hashString();
		return result.OBJ_VAL();
	}

	public static inline function CONST_STRING(vm:VM, text:String) {
		return newString(vm, text);
	}

	public static function numToString(vm:VM, value:Float) {
		// Edge case: If the value is NaN or infinity, different versions of libc
		// produce different outputs (some will format it signed and some won't). To
		// get reliable output, handle it ourselves.
		if (Math.isNaN(value))
			return CONST_STRING(vm, "nan");
		if (Math.isFinite(value)) {
			if (value > 0.0) {
				return CONST_STRING(vm, "infinity");
			} else {
				return CONST_STRING(vm, "-infinity");
			}
        }
        
        // This is large enough to hold any double converted to a string using
        // "%.14g". Example:
        //
        //     -1.12345678901234e-1022
        //
        // So we have:
        //
        // + 1 char for sign
        // + 1 char for digit
        // + 1 char for "."
        // + 14 chars for decimal digits
        // + 1 char for "e"
        // + 1 char for "-" or "+"
        // + 4 chars for exponent
        // + 1 char for "\0"
        // = 24

        return newString(vm, '$value');
    }
    
    public static function fromCodePoint(vm:VM, code:Int) {
        var s:UnicodeString = String.fromCharCode(code);
        return newString(vm, s);
    }

    public static function fromByte(vm:VM, byte:Int) {
        var b = Bytes.alloc(1);
        b.set(0, byte);
        return newString(vm, b.toString());
    }

    public static function codePointAt(vm:VM, string:ObjString, index:Int) {
        if(index > string.length) throw "Index out of bounds.";
        return fromCodePoint(vm, string.value[index].charCodeAt(0));
    }

    public static function find(vm:VM, from:ObjString, string:ObjString) {
       return  StringTools.contains(from.value.join(''), string.value.join(''));
    }
}
