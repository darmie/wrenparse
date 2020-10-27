package wrenparse;

import haxe.io.Bytes;
import haxe.Int64;
import polygonal.ds.ArrayList;

class Utils {
	public static function wrenPowerOf2Ceil(n:Int):Int {
		n--;
		n |= n >> 1;
		n |= n >> 2;
		n |= n >> 4;
		n |= n >> 8;
		n |= n >> 16;
		n++;

		return n;
	}

	public static function hashBits(hash:haxe.Int64) {
		// From v8's ComputeLongHash() which in turn cites:
		// Thomas Wang, Integer Hash Functions.
		// http://www.concentric.net/~Ttwang/tech/inthash.htm
		hash = ~hash + (hash << 18); // hash = (hash << 18) - hash - 1;
		hash = hash ^ (hash >> 31);
		hash = hash * 21; // hash = (hash + (hash << 2)) + (hash << 4);
		hash = hash ^ (hash >> 11);
		hash = hash + (hash << 6);
		hash = hash ^ (hash >> 22);
		return hash & 0x3fffffff;
	}

	/**
	 * Generates a hash code for [num].
	 * @param v
	 */
	public static function hashNumber(v:Float) {
		return hashBits(Int64.fromFloat(v));
	}

	public static function ASSERT(condition:Bool, message:String) {
		if (!condition)
			throw message;
	}

	public static function UNREACHABLE() {
		throw "This code should not be reached";
	}

	// Returns `true` if [name] is a local variable name (starts with a lowercase
	// letter).
	public static inline function isLocalName(name:String) {
		return name.charCodeAt(0) >= 'a'.charCodeAt(0) && name.charCodeAt(0) <= 'z'.charCodeAt(0);
	}

	public static function getEnclosingClassCompiler(compiler:Compiler) {
		while (compiler != null) {
			if (compiler.enclosingClass != null)
				return compiler;
			compiler = compiler.parent;
		}
		return null;
	}

	public static function getEnclosingClass(compiler:Compiler) {
		compiler = getEnclosingClassCompiler(compiler);
		return compiler == null ? null : compiler.enclosingClass;
	}


	public static inline function utf8EncodeNumBytes(value:Int){
		Utils.ASSERT(value >= 0, "Cannot encode a negative value.");

		if (value <= 0x7f) return 1;
		if (value <= 0x7ff) return 2;
		if (value <= 0xffff) return 3;
		if (value <= 0x10ffff) return 4;
		return 0;
	}

	public static function utf8Encode(value:Int, bytes:Bytes){
		if (value <= 0x7f)
			{
			  // Single byte (i.e. fits in ASCII).
			  bytes.set(0, value & 0x7f);
			  return 1;
			}
			else if (value <= 0x7ff)
			{
			  // Two byte sequence: 110xxxxx 10xxxxxx.
			  bytes.set(0, 0xc0 | ((value & 0x7c0) >> 6));
			  bytes.set(1, 0x80 | (value & 0x3f));
			  return 2;
			}
			else if (value <= 0xffff)
			{
			  // Three byte sequence: 1110xxxx 10xxxxxx 10xxxxxx.
			  bytes.set(0, 0xe0 | ((value & 0xf000) >> 12));
			  bytes.set(1, 0x80 | ((value & 0xfc0) >> 6));
			  bytes.set(2, 0x80 | (value & 0x3f));
			  return 3;
			}
			else if (value <= 0x10ffff)
			{
			  // Four byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx.
			  bytes.set(0, 0xf0 | ((value & 0x1c0000) >> 18));
			  bytes.set(1, 0x80 | ((value & 0x3f000) >> 12));
			  bytes.set(2, 0x80 | ((value & 0xfc0) >> 6));
			  bytes.set(3, 0x80 | (value & 0x3f));
			  return 4;
			}

			UNREACHABLE();
			return 0;
	}
}




@:forward(size, free, resize)
abstract FixedArray<T>(ArrayList<T>) from ArrayList<T> to ArrayList<T> {
	public inline function new(size:Int) {
		this = new ArrayList<T>(size);
	}

	@:arrayAccess
	public inline function get(i:Int):T {
		return this.get(i);
	}

	@:arrayAccess
	public inline function set(i:Int, v:T) {
		this.set(i, v);
	}
}
