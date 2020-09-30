package wrenparse.objects;

import wrenparse.VM;

class ObjRange extends Obj {

    /**
     * The beginning of the range.
     */
    public var from:Float;

    /**
     * The end of the range. May be greater or less than [from].
     */
    public var to:Float;

    /**
     * True if [to] is included in the range.
     */
    public var isInclusive:Bool;

    public function new(vm:VM, from:Float, to:Float, isInclusive:Bool) {
        this.from = from;
        this.to = to;
        this.isInclusive = isInclusive;
        this.type = OBJ_RANGE;

        super(vm, this.type, vm.rangeClass);
    }

    public static function newRange(vm:VM, from:Float, to:Float, isInclusive:Bool) {
        var r = new ObjRange(vm, from, to, isInclusive);
        return r.OBJ_VAL();
    }
}