package wrenparse.objects;

class ObjForeign extends Obj {
    public var data:Array<Int>;

    public function new() {
        super();
        this.type = OBJ_FOREIGN;
    }
}