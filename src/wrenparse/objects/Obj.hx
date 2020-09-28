package wrenparse.objects;


/**
 * Identifies which specific type a heap-allocated object is.
 */
enum ObjType {
    OBJ_CLASS;
    OBJ_CLOSURE;
    OBJ_FIBER;
    OBJ_FN;
    OBJ_FOREIGN;
    OBJ_INSTANCE;
    OBJ_LIST;
    OBJ_MAP;
    OBJ_MODULE;
    OBJ_RANGE;
    OBJ_STRING;
    OBJ_UPVALUE;
  } 


/**
 * Base class for all heap-allocated objects.
 */
class Obj{
    public var type:ObjType;
    public var isDark:Bool;
    /**
     * The object's class.
     */
    public var classObj:ObjClass;
    /**
     * The next object in the linked list of all currently allocated objects.
     */
    public var next:Obj;

    public function new() {
        
    }

    public  function OBJ_VAL() {
      var value = new Value(VAL_OBJ);
      value.as.obj = this;
      return value;
    }
}