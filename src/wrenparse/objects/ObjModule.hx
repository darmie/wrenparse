package wrenparse.objects;

import wrenparse.IO.SymbolTable;
import wrenparse.Value.ValueBuffer;
import wrenparse.VM;

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

	public function new(vm:VM, name:ObjString) {
		super(vm, OBJ_MODULE, null);
		this.type = OBJ_MODULE;
		vm.pushRoot(this);

		this.variables = new ValueBuffer(vm);
		this.variableNames = new SymbolTable(vm);
		this.name = name;

		vm.popRoot();
	}

	public function defineVariable(vm:VM, name:String, length:Int, value:Value, line:Int):Int {
		if (variables.count == Compiler.MAX_MODULE_VARS)
			return -2;
		if (value.IS_OBJ())
			vm.pushRoot(value.AS_OBJ());
		// See if the variable is already explicitly or implicitly declared.
		var symbol = variableNames.find(name);
		if (symbol == -1) {
			// Brand new variable.
			symbol = variableNames.add(name);
			variables.write(value);
		} else if (variables.data[symbol].IS_NUM()) {
			// An implicitly declared variable's value will always be a number.
			// Now we have a real definition.
			if (line != 0)
				line = Std.int(variables.data[symbol].AS_NUM());
			variables.data[symbol] = value;

			// If this was a localname we want to error if it was
			// referenced before this definition.
			if (Utils.isLocalName(name))
				symbol = -3;
		} else {
			// Already explicitly declared.
			symbol = -1;
		}

		if (value.IS_OBJ())
			vm.popRoot();

		return symbol;
	}
}
