package wrenparse.objects;

import wrenparse.Utils.FixedArray;

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

    public function new() {
        super();
        this.type = OBJ_STRING;
    }


}