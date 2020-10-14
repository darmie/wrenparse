package wrenparse;

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
		#if debug
		if (!condition)
			throw message;
		#end
	}

	public static function UNREACHABLE() {
		throw "This code should not be reached";
	}

	// Returns `true` if [name] is a local variable name (starts with a lowercase
	// letter).
	public static inline function isLocalName(name:String) {
		return name.charCodeAt(0) >= 'a'.charCodeAt(0) && name.charCodeAt(0) <= 'z'.charCodeAt(0);
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
