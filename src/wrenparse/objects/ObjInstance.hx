package wrenparse.objects;

class ObjInstance extends Obj {
    public var fields:Array<Value>;

    public function new() {
        super();
        this.type = OBJ_INSTANCE;
    }
}