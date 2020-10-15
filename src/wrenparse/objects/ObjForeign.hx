package wrenparse.objects;

import wrenparse.VM;
import wrenparse.Utils;

class ObjForeign extends Obj {
	public var data:Dynamic;

	public function new(vm:VM, classObj:ObjClass, data:Dynamic) {
		super(vm, OBJ_FOREIGN, classObj);
        this.data = data;
		this.type = OBJ_FOREIGN;
	}

	public function finalize(vm:VM) {
		// TODO: Don't look up every time.
		var symbol = vm.methodNames.find("<finalize>");
		Utils.ASSERT(symbol != -1, "Should have defined <finalize> symbol.");
		// If there are no finalizers, don't finalize it.
		if (symbol == -1)
			return;

		// If the class doesn't have a finalizer, bail out.
		var classObj:ObjClass = classObj;
		if (symbol >= classObj.methods.count)
            return;
        
        var method = classObj.methods.data[symbol];
        if (method.type == METHOD_NONE) return;
        Utils.ASSERT(method.type == METHOD_FOREIGN, "Finalizer should be foreign.");
        var finalizer:WrenFinalizerFn = cast method.as.foreign;
        finalizer(data);
	}
}
