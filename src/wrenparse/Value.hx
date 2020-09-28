package wrenparse;

import wrenparse.objects.Obj;
import wrenparse.IO.Buffer;

enum ValueType {
    VAL_FALSE;
    VAL_NULL;
    VAL_NUM;
    VAL_TRUE;
    VAL_UNDEFINED;
    VAL_OBJ;
}


typedef ValueBuffer = Buffer<Value>;

/**
 * The type of a primitive function.
 * 
 * Primitives are similiar to foreign functions, but have more direct access to
 * VM internals. It is passed the arguments in [args]. If it returns a value,
 * it places it in `args[0]` and returns `true`. If it causes a runtime error
 * or modifies the running fiber, it returns `false`.
 */
typedef Primitive = (vm:Dynamic, args:Array<Value>)->Bool;


typedef ValueAs = {
    ?num:Float,
    ?obj:Obj
}

class Value {
    public var type:ValueType;
    public var as:ValueAs; // num or object

    public function new(type:ValueType) {
        this.type = type;
    }


    public inline function IS_OBJ() {
        return this.type == VAL_OBJ;
    }

    public inline function IS_FALSE() {
        return this.type == VAL_FALSE;
    }

    public inline function IS_TRUE() {
        return this.type == VAL_TRUE;
    }

    public inline function IS_NUM() {
        return this.type == VAL_NUM;
    }

    public inline function IS_UNDEFINED() {
        return this.type == VAL_UNDEFINED;
    }

    public inline function IS_NULL() {
        return this.type == VAL_NULL;
    }


    public static inline function NUM_VAL(i:Int){
        final v = new Value(VAL_NUM);
        v.as.num = i;
        return v;
    }

    public static inline function NULL_VAL(){
        final v = new Value(VAL_NULL);
        return v;
    }
}

