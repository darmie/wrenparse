package wrenparse.objects;

import wrenparse.Value.ValueBuffer;

class ObjList extends Obj {
    /**
     * The elements in the list.
     */
    public var elements:ValueBuffer;

    public function new() {
        super();
        this.type = OBJ_LIST;
    }
}