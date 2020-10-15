package wrenparse;

import haxe.ds.Vector;

class Pointer<T> {
	public var arr: Array<T>;
	var index: Int;

	public function new(arr:Array<T>, index: Int = 0) {
		this.arr = arr;
		this.index = index;
	}

	public inline function value(index: Int = 0): T {
		return arr[this.index + index];
	}

	public inline function setValue(index: Int, value: T): Void {
		arr[this.index + index] = value;
	}

	public inline function inc(): Void {
		++index;
	}

	public inline function dec(): Void {
		--index;
	}

	public inline function drop(): Void {
		index--;
	}

	public inline function pointer(index: Int): Pointer<T> {
		return new Pointer<T>(arr, this.index + index);
	}

	public inline function sub(pointer: Pointer<T>): Int {
		return index - pointer.index;
	}

	public inline function lt(pointer: Pointer<T>): Bool {
		return index < pointer.index;
	}

	public inline function gte(pointer: Pointer<T>): Bool {
		return index >= pointer.index;
	}

	public inline function lte(pointer: Pointer<T>): Bool {
		return index <= pointer.index;
	}
}