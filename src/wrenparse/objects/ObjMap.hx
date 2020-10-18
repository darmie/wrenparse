package wrenparse.objects;

import haxe.Int64;
import haxe.ds.Vector;
import wrenparse.Compiler;

class MapEntry {
	/**
	 * The entry's key, or UNDEFINED_VAL if the entry is not in use.
	 */
	public var key:Value;

	/**
	 * The value associated with the key. If the key is UNDEFINED_VAL, this will
	 * be false to indicate an open available entry or true to indicate a
	 * tombstone -- an entry that was previously in use but was then deleted.
	 */
	public var value:Value;

	public function new(key:Value, value:Value) {
		this.key = key;
		this.value = value;
	}
}

/**
 * A hash table mapping keys to values.
 *
 * We use something very simple: open addressing with linear probing. The hash
 * table is an array of entries. Each entry is a key-value pair. If the key is
 * the special UNDEFINED_VAL, it indicates no value is currently in that slot.
 * Otherwise, it's a valid key, and the value is the value associated with it.
 *
 * When entries are added, the array is dynamically scaled by GROW_FACTOR to
 * keep the number of filled slots under MAP_LOAD_PERCENT. Likewise, if the map
 * gets empty enough, it will be resized to a smaller array. When this happens,
 * all existing entries are rehashed and re-added to the new array.
 *
 * When an entry is removed, its slot is replaced with a "tombstone". This is an
 * entry whose key is UNDEFINED_VAL and whose value is TRUE_VAL. When probing
 * for a key, we will continue past tombstones, because the desired key may be
 * found after them if the key that was removed was part of a prior collision.
 * When the array gets resized, all tombstones are discarded.
 */
class ObjMap extends Obj {
	/**
	 * The number of entries allocated.
	 */
	public var capacity:Int;

	/**
	 * The number of entries in the map.
	 */
	public var count:Int;

	/**
	 * Pointer to a contiguous array of [capacity] entries.
	 */
	public var entries:Pointer<MapEntry>;

	private var baseMap:Map<Value, Value>;

	public function new(vm:VM) {
		super(vm, OBJ_MAP, vm.mapClass);
		this.type = OBJ_MAP;
		this.capacity = 0;
		this.count = 0;
		this.entries = new Pointer([]);
		baseMap = new Map();
	}

	public function get(vm:VM, key:Value) {
		// var entry:MapEntry = new MapEntry(null, null);
		// if (findEntry(vm, capacity, key, entry))
		// 	return entry.value;

		// return Value.UNDEFINED_VAL();
		if(key.type == VAL_NULL){
			for(_v in baseMap.keys()){
				if(_v.IS_NULL()){
					return baseMap.get(_v);
				}
			}
		}
		var v = baseMap.get(key);
		if (v == null)
			return Value.UNDEFINED_VAL();

		return v;
	}

	public function set(vm:VM, key:Value, value:Value) {
		// // If the map is getting too full, make room first.
		// if (count + 1 > this.capacity * Compiler.MAP_LOAD_PERCENT / 100) {
		// 	// Figure out the new hash table size.
		// 	var capacity = this.capacity * Compiler.GROW_FACTOR;
		// 	if (capacity < Compiler.MIN_CAPACITY)
		// 		this.capacity = Compiler.MIN_CAPACITY;
		// }
		// if (insertEntry(vm, capacity, key, value)) {s
		// 	// A new key was added.
		// 	count++;
		// }
		
		this.baseMap.set(key, value);
		this.entries.setValue(0, new MapEntry(key, value));
		this.count++;
	}

	public function findEntry(key:Value) {
		return this.baseMap.exists(key);
	}

	// public function findEntry(vm:VM, capacity:Int, key:Value, result:MapEntry) {
	// 	// If there is no entry array (an empty map), we definitely won't find it.
	// 	if (capacity == 0)
	// 		return false;
	// 	// Figure out where to insert it in the table. Use open addressing and
	// 	// basic linear probing.
	// 	var startIndex:Int = Int64.toInt(key.hash() % capacity);
	// 	var index = startIndex;
	// 	// If we pass a tombstone and don't end up finding the key, its entry will
	// 	// be re-used for the insert.
	// 	var tombstone:Pointer<MapEntry> = null;
	// 	// Walk the probe sequence until we've tried every slot.
	// 	do {
	// 		var entry = entries.value(index);
	// 		if (entry.key.IS_UNDEFINED()) {
	// 			// If we found an empty slot, the key is not in the table. If we found a
	// 			// slot that contains a deleted key, we have to keep looking.
	// 			if (entry.value.IS_FALSE()) {
	// 				// We found an empty slot, so we've reached the end of the probe
	// 				// sequence without finding the key. If we passed a tombstone, then
	// 				// that's where we should insert the item, otherwise, put it here at
	// 				// the end of the sequence.
	// 				result = tombstone != null ? tombstone.value() : entry;
	// 				return false;
	// 			} else {
	// 				// We found a tombstone. We need to keep looking in case the key is
	// 				// after it, but we'll use this entry as the insertion point if the
	// 				// key ends up not being found.
	// 				if (tombstone == null)
	// 					tombstone = new Pointer([entry]);
	// 			}
	// 		} else if (Value.equal(entry.key, key)) {
	// 			// We found the key.
	// 			result = entry;
	// 			return true;
	// 		}
	// 		// Try the next slot.
	// 		index = (index + 1) % capacity;
	// 	} while (index != startIndex);
	// 		// If we get here, the table is full of tombstones. Return the first one we
	// 		// found.
	// 	Utils.ASSERT(tombstone != null, "Map should have tombstones or empty entries.");
	// 	result = tombstone.value();
	// 	return false;
	// }
	// public function insertEntry(vm:VM, capacity:Int, key:Value, value:Value) {
	// 	Utils.ASSERT(entries != null, "Should ensure capacity before inserting.");
	// 	if (findEntry(key)) {
	// 		// Already present, so just replace the value.
	// 		this.baseMap.set(key,)
	// 		return false;
	// 	} else {
	// 		entry.key = key;
	// 		entry.value = value;
	// 		return true;
	// 	}
	// }
	// public function resizeMap(vm:VM, capacity:Int) {}

	public function clear() {
		this.baseMap.clear();
		this.entries = null;
		this.capacity = 0;
		this.count = 0;
	}

	public function removeKey(vm:VM, key:Value) {
		var value = this.baseMap.get(key);
		if (this.baseMap.remove(key)) {
			if (value.IS_OBJ())
				vm.pushRoot(value.AS_OBJ());
			this.count--;
			for (e in entries.arr) {
				if (e.key == key)
					entries.arr.remove(e);
			}
			if (value.IS_OBJ())
				vm.popRoot();
		}
		return value;
	}

	public static function validateKey(vm:VM, arg:Value) {
		if (arg.IS_BOOL() || arg.IS_CLASS() || arg.IS_NULL() || arg.IS_NUM() || arg.IS_RANGE() || arg.IS_STRING()) {
			return true;
		}

		// RETURN_ERROR("Key must be a value type.");
		do {
			vm.fiber.error = ObjString.newString(vm, "Key must be a value type.");
			return false;
		} while (false);
		return false;
	}
}
