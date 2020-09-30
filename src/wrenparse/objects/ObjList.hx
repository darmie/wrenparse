package wrenparse.objects;

import haxe.ds.Vector;
import haxe.Int64;
import haxe.Int64Helper;
import wrenparse.objects.ObjMap.MapEntry;
import wrenparse.Value.ValueBuffer;

class ObjList extends Obj {
	/**
	 * The elements in the list.
	 */
	public var elements:ValueBuffer;

	public function new(vm:VM, numElements:Int) {
		var elements = null;
		if (numElements > 0) {
			var elements = new ValueBuffer(vm);
			elements.fill(Value.NULL_VAL(), numElements);
		}
		super(vm, OBJ_LIST, vm.listClass);
		this.elements.count = numElements;
		this.elements.capacity = numElements;
		this.elements.data = elements;

		this.type = OBJ_LIST;
	}

	public function insert(vm:VM, value:Value, index:Int) {
		if (value.IS_OBJ())
			vm.pushRoot(value.AS_OBJ());
		// Add a slot at the end of the list.
		this.elements.write(Value.NULL_VAL());

		if (value.IS_OBJ())
			vm.popRoot();

		// Shift the existing elements down.
		var i = this.elements.count - 1;

		while (i > index) {
			this.elements.data[i] = this.elements.data[i - 1];
			i--;
		}

		// Store the new element.
		this.elements.data[index] = value;
	}

	public function removeAt(vm:VM, index:Int) {
		var removed = this.elements.data[index];
		if (removed.IS_OBJ())
			vm.pushRoot(removed.AS_OBJ());

		for (i in index...this.elements.count) {
			this.elements.data[i] = this.elements.data[i + 1];
		}

		// If we have too much excess capacity, shrink it.
		if ((this.elements.capacity / Compiler.GROW_FACTOR) >= this.elements.count) {
			this.elements.capacity = Std.int(this.elements.capacity / Compiler.GROW_FACTOR);
		}

		if (removed.IS_OBJ())
			vm.popRoot();

		this.elements.count--;

		return removed;
	}
}



