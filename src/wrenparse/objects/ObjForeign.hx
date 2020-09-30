package wrenparse.objects;

class ObjForeign extends Obj {
    public var data:Array<Int>;

    public function new(vm:VM, classObj:ObjClass, size:Int) {
        super(vm, OBJ_FOREIGN, classObj);
 
        this.type = OBJ_FOREIGN;

        data = [];
    }
}