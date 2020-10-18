package wrenparse;

import polygonal.ds.tools.mem.ByteMemory;
import haxe.io.UInt8Array;
import haxe.io.UInt16Array;
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


class DataPointer {
	public var arr:ByteMemory;
	var index: Int;

	public function new(arr:ByteMemory, index: Int = 0) {
		this.arr = arr;
		this.index = index;
	}

	public inline function value(index: Int = 0): Int {
		return arr.get(this.index + index);
	}

	public inline function setValue(index: Int, value: Int): Void {
		arr.set(this.index + index,  value);
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

	public inline function pointer(index: Int): DataPointer {
		return new DataPointer(arr, this.index + index);
	}

	public inline function sub(pointer: DataPointer): Int {
		return index - pointer.index;
	}

	public inline function lt(pointer: DataPointer): Bool {
		return index < pointer.index;
	}

	public inline function gte(pointer: DataPointer): Bool {
		return index >= pointer.index;
	}

	public inline function lte(pointer: DataPointer): Bool {
		return index <= pointer.index;
	}
}