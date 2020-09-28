package wrenparse.objects;

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

    public function new() {
        super();

        this.type = OBJ_RANGE;
    }
}