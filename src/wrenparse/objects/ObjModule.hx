package wrenparse.objects;

import wrenparse.IO.SymbolTable;
import wrenparse.Value.ValueBuffer;

/**
 * A loaded module and the top-level variables it defines.
 * 
 * While this is an Obj and is managed by the GC, it never appears as a
 * first-class object in Wren.
 */
class ObjModule extends Obj {
    
    /**
     * The currently defined top-level variables.
     */
    public var variables:ValueBuffer;

    /**
     * Symbol table for the names of all module variables. Indexes here directly
     * correspond to entries in [variables].
     */
    public var variableNames:SymbolTable;

    /**
     * The name of the module.
     */
    public var name:ObjString;

    public function new() {
        super();
        this.type = OBJ_MODULE;
    }
}