package wrenparse.objects;

import wrenparse.Value;
import wrenparse.VM;

class ObjInstance extends Obj {
    public var fields:Array<Value>;

    public var numFields:Int;

    public function new(vm:VM, classObj:ObjClass) {
        this.fields = [];
        this.numFields = classObj.numFields;
        this.type = OBJ_INSTANCE;
        super(vm, OBJ_INSTANCE, classObj);
        for(i in 0...numFields){
            this.fields[i] = Value.NULL_VAL();
        }
    }

    public static function newInstance(vm:VM, classObj:ObjClass) {
        return new ObjInstance(vm, classObj).OBJ_VAL();
    }
}