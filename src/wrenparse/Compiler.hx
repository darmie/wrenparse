package wrenparse;

import haxe.io.Bytes;
import byte.ByteData;
import wrenparse.Data.Token;
import haxe.io.FPHelper;
import wrenparse.objects.*;
import wrenparse.Utils.FixedArray;
import wrenparse.IO.IntBuffer;
import wrenparse.IO.SymbolTable;
import wrenparse.Data.StatementDef;
using StringTools;

typedef Local = {
	// The name of the local variable. This points directly into the original
	// source code string.
	name:String,
	// The length of the local variable's name.
	length:Int,
	// The depth in the scope chain that this variable was declared at. Zero is
	// the outermost scope--parameters for a method, or the first local block in
	// top level code. One is the scope within that, etc.
	depth:Int,
	// If this local variable is being used as an upvalue.
	isUpvalue:Bool
}

typedef CompilerUpvalue = {
	// True if this upvalue is capturing a local variable from the enclosing
	// function. False if it's capturing an upvalue.
	isLocal:Bool,
	// The index of the local or upvalue being captured in the enclosing function.
	index:Int
}

/**
 *  Bookkeeping information for the current loop being compiled.
 */
typedef Loop = {
	// Index of the instruction that the loop should jump back to.
	start:Int,
	// Index of the argument for the CODE_JUMP_IF instruction used to exit the
	// loop. Stored so we can patch it once we know where the loop ends.
	exitJump:Int,
	// Index of the first instruction of the body of the loop.
	body:Int,
	// Depth of the scope(s) that need to be exited if a break is hit inside the
	// loop.
	scopDepth:Int,
	// The loop enclosing this one, or NULL if this is the outermost loop.
	enclosing:Null<Loop>,
}

/**
 * The different signature syntaxes for different kinds of methods.
 */
enum SignatureType {
	// A name followed by a (possibly empty) parenthesized parameter list. Also
	// used for binary operators.
	SIG_METHOD;

	// Just a name. Also used for unary operators.
	SIG_GETTER;
	// A name followed by "=".
	SIG_SETTER;
	// A square bracketed parameter list.
	SIG_SUBSCRIPT;
	// A square bracketed parameter list followed by "=".
	SIG_SUBSCRIPT_SETTER;
	// A constructor initializer function. This has a distinct signature to
	// prevent it from being invoked directly outside of the constructor on the
	// metaclass.
	SIG_INITIALIZER;
}

typedef Signature = {
	type:SignatureType,
	length:Int,
	name:String,
	arity:Int
}

/**
 * Bookkeeping information for compiling a class definition.
 */
typedef ClassInfo = {
	// The name of the class.
	?name:ObjString,
	// Symbol table for the fields of the class.
	?fields:SymbolTable,
	// Symbols for the methods defined by the class. Used to detect duplicate
	// method definitions.
	?methods:IntBuffer,
	?staticMethods:IntBuffer,
	// True if the class being compiled is a foreign class.
	?isForeign:Bool,
	// True if the current method being compiled is static.
	?inStatic:Bool,
	// The signature of the method being compiled.
	?signature:Signature
}

/**
 *  Describes where a variable is declared
 */
enum Scope {
	// A local variable in the current function.
	SCOPE_LOCAL;

	// A local variable declared in an enclosing function.
	SCOPE_UPVALUE;
	// A top-level module variable.
	SCOPE_MODULE;
}

/**
 * A reference to a variable and the scope where it is defined. This contains
 * enough information to emit correct code to load or store the variable.
 */
class Variable {
	/**
	 * The stack slot, upvalue slot, or module symbol defining the variable
	 */
	public var index:Int;

	/**
	 * Where the variable is declared.
	 */
	public var scope:Scope;

	public function new(index:Int, scope:Scope) {
		this.index = index;
		this.scope = scope;
	}
}

/**
 * https://github.com/wren-lang/wren/blob/main/src/vm/wren_opcodes.h
 */
enum abstract Code(Int) from Int to Int {
	/**
	 * Load the constant at index [arg].
	 */
	var CODE_CONSTANT = 0;

	/**
	 * Push null onto the stack.
	 */
	var CODE_NULL;

	/**
	 * Push false onto the stack.
	 */
	var CODE_FALSE;

	/**
	 * Push true onto the stack.
	 */
	var CODE_TRUE;

	/**
	 * Pushes the value in the given local slot.
	 */
	var CODE_LOAD_LOCAL_0;

	var CODE_LOAD_LOCAL_1;
	var CODE_LOAD_LOCAL_2;
	var CODE_LOAD_LOCAL_3;
	var CODE_LOAD_LOCAL_4;
	var CODE_LOAD_LOCAL_5;
	var CODE_LOAD_LOCAL_6;
	var CODE_LOAD_LOCAL_7;
	var CODE_LOAD_LOCAL_8;

	/**
	 * Pushes the value in local slot [arg].
	 */
	var CODE_LOAD_LOCAL;

	/**
	 * Stores the top of stack in local slot [arg]. Does not pop it.
	 */
	var CODE_STORE_LOCAL;

	/**
	 * Pushes the value in upvalue [arg].
	 */
	var CODE_LOAD_UPVALUE;

	/**
	 * Stores the top of stack in upvalue [arg]. Does not pop it.
	 */
	var CODE_STORE_UPVALUE;

	/**
	 * Pushes the value of the top-level variable in slot [arg].
	 */
	var CODE_LOAD_MODULE_VAR;

	/**
	 * Stores the top of stack in top-level variable slot [arg]. Does not pop it.
	 */
	var CODE_STORE_MODULE_VAR;

	/**
	 * Pushes the value of the field in slot [arg] of the receiver of the current
	 * function. This is used for regular field accesses on "this" directly in
	 * methods. This instruction is faster than the more general CODE_LOAD_FIELD
	 * instruction.
	 */
	var CODE_LOAD_FIELD_THIS;

	/**
	 * Stores the top of the stack in field slot [arg] in the receiver of the
	 * current value. Does not pop the value. This instruction is faster than the
	 * more general CODE_LOAD_FIELD instruction.
	 */
	var CODE_STORE_FIELD_THIS;

	/**
	 * Pops an instance and pushes the value of the field in slot [arg] of it.
	 */
	var CODE_LOAD_FIELD;

	/**
	 * Pops an instance and stores the subsequent top of stack in field slot
	 * [arg] in it. Does not pop the value.
	 */
	var CODE_STORE_FIELD;

	/**
	 * Pop and discard the top of stack.
	 */
	var CODE_POP;

	/**
	 * Invoke the method with symbol [arg]. The number indicates the number of
	 * arguments (not including the receiver).
	 */
	var CODE_CALL_0;

	var CODE_CALL_1;
	var CODE_CALL_2;
	var CODE_CALL_3;
	var CODE_CALL_4;
	var CODE_CALL_5;
	var CODE_CALL_6;
	var CODE_CALL_7;
	var CODE_CALL_8;
	var CODE_CALL_9;
	var CODE_CALL_10;
	var CODE_CALL_11;
	var CODE_CALL_12;
	var CODE_CALL_13;
	var CODE_CALL_14;
	var CODE_CALL_15;
	var CODE_CALL_16;

	/**
	 * Invoke a superclass method with symbol [arg]. The number indicates the
	 * number of arguments (not including the receiver).
	 */
	var CODE_SUPER_0;

	var CODE_SUPER_1;
	var CODE_SUPER_2;
	var CODE_SUPER_3;
	var CODE_SUPER_4;
	var CODE_SUPER_5;
	var CODE_SUPER_6;
	var CODE_SUPER_7;
	var CODE_SUPER_8;
	var CODE_SUPER_9;
	var CODE_SUPER_10;
	var CODE_SUPER_11;
	var CODE_SUPER_12;
	var CODE_SUPER_13;
	var CODE_SUPER_14;
	var CODE_SUPER_15;
	var CODE_SUPER_16;
	var CODE_JUMP;
	var CODE_LOOP;
	var CODE_JUMP_IF;
	var CODE_AND;
	var CODE_OR;
	var CODE_CLOSE_UPVALUE;
	var CODE_RETURN;
	var CODE_CLOSURE;
	var CODE_CONSTRUCT;
	var CODE_FOREIGN_CONSTRUCT;
	var CODE_CLASS;
	var CODE_FOREIGN_CLASS;
	var CODE_METHOD_INSTANCE;
	var CODE_METHOD_STATIC;
	var CODE_END_MODULE;
	var CODE_IMPORT_MODULE;
	var CODE_IMPORT_VARIABLE;
	var CODE_END;

	public inline function stackEffect() {
		return switch this {
			case CODE_CONSTANT | CODE_NULL | CODE_FALSE | CODE_TRUE | CODE_LOAD_LOCAL_0 | CODE_LOAD_LOCAL_1 | CODE_LOAD_LOCAL_2 | CODE_LOAD_LOCAL_3 |
				CODE_LOAD_LOCAL_4 | CODE_LOAD_LOCAL_5 | CODE_LOAD_LOCAL_6 | CODE_LOAD_LOCAL_7 | CODE_LOAD_LOCAL_8 | CODE_LOAD_LOCAL | CODE_LOAD_UPVALUE |
				CODE_LOAD_MODULE_VAR | CODE_LOAD_FIELD_THIS | CODE_LOAD_FIELD | CODE_CLOSURE | CODE_END_MODULE | CODE_IMPORT_MODULE | CODE_IMPORT_VARIABLE: 1;
			case CODE_STORE_LOCAL | CODE_STORE_UPVALUE | CODE_STORE_MODULE_VAR | CODE_STORE_FIELD_THIS | CODE_STORE_FIELD | CODE_CALL_0 | CODE_SUPER_0 |
				CODE_JUMP | CODE_LOOP | CODE_RETURN | CODE_CONSTRUCT | CODE_FOREIGN_CONSTRUCT | CODE_END: 0;
			case CODE_POP | CODE_CALL_1 | CODE_SUPER_1 | CODE_JUMP_IF | CODE_AND | CODE_OR | CODE_CLOSE_UPVALUE | CODE_CLASS | CODE_FOREIGN_CLASS: -1;
			case CODE_CALL_2 | CODE_METHOD_INSTANCE | CODE_METHOD_STATIC: -2;
			case CODE_CALL_3: -3;
			case CODE_CALL_4: -4;
			case CODE_CALL_5: -5;
			case CODE_CALL_6: -6;
			case CODE_CALL_7: -7;
			case CODE_CALL_8: -8;
			case CODE_CALL_9: -9;
			case CODE_CALL_10: -10;
			case CODE_CALL_11: -11;
			case CODE_CALL_12: -12;
			case CODE_CALL_13: -13;
			case CODE_CALL_14: -14;
			case CODE_CALL_15: -15;
			case CODE_CALL_16: -12;

			case CODE_SUPER_2: -2;
			case CODE_SUPER_3: -3;
			case CODE_SUPER_4: -4;
			case CODE_SUPER_5: -5;
			case CODE_SUPER_6: -6;
			case CODE_SUPER_7: -7;
			case CODE_SUPER_8: -8;
			case CODE_SUPER_9: -9;
			case CODE_SUPER_10: -10;
			case CODE_SUPER_11: -11;
			case CODE_SUPER_12: -12;
			case CODE_SUPER_13: -13;
			case CODE_SUPER_14: -14;
			case CODE_SUPER_15: -15;
			case CODE_SUPER_16: -12;
			case _: throw "invalid opcode";
		}
	}
}

class Compiler {
	public var parser:WrenParser;

	/**
	 * The maximum number of module-level variables that may be defined at one time.
	 * This limitation comes from the 16 bits used for the arguments to
	 * `CODE_LOAD_MODULE_VAR` and `CODE_STORE_MODULE_VAR`.
	 */
	public static final MAX_MODULE_VARS = 65536;

	/**
	 * The maximum number of arguments that can be passed to a method. Note that
	 * this limitation is hardcoded in other places in the VM, in particular, the
	 * `CODE_CALL_XX` instructions assume a certain maximum number.
	 */
	public static final MAX_PARAMETERS = 16;

	/**
	 * The maximum name of a method, not including the signature.
	 */
	public static final MAX_METHOD_NAME = 64;

	/**
	 * The maximum length of a method signature. Signatures look like:
	 *
	 * ```
	 * foo        // Getter.
	 * foo()      // No-argument method.
	 * foo(_)     // One-argument method.
	 * foo(_,_)   // Two-argument method.
	 * init foo() // Constructor initializer.
	 * ```
	 * The maximum signature length takes into account the longest method name, the
	 * maximum number of parameters with separators between them, "init ", and "()".
	 */
	public static final MAX_METHOD_SIGNATURE = (MAX_METHOD_NAME + (MAX_PARAMETERS * 2) + 6);

	/**
	 * The maximum length of an identifier. The only real reason for this limitation
	 * is so that error messages mentioning variables can be stack allocated.
	 */
	public static final MAX_VARIABLE_NAME = 64;

	/**
	 * The maximum number of fields a class can have, including inherited fields.
	 * This is explicit in the bytecode since `CODE_CLASS` and `CODE_SUBCLASS` take
	 * a single byte for the number of fields. Note that it's 255 and not 256
	 * because creating a class takes the *number* of fields, not the *highest
	 * field index*.
	 */
	public static final MAX_FIELDS = 255;

	/**
	 * The maximum number of local (i.e. not module level) variables that can be
	 * declared in a single function, method, or chunk of top level code. This is
	 * the maximum number of variables in scope at one time, and spans block scopes.
	 *
	 * Note that this limitation is also explicit in the bytecode. Since
	 * `CODE_LOAD_LOCAL` and `CODE_STORE_LOCAL` use a single argument byte to
	 * identify the local, only 256 can be in scope at one time.
	 */
	public static final MAX_LOCALS = 256;

	/**
	 * The maximum number of upvalues (i.e. variables from enclosing functions)
	 * that a function can close over.
	 */
	public static final MAX_UPVALUES = 256;

	/**
	 * The maximum number of distinct constants that a function can contain. This
	 * value is explicit in the bytecode since `CODE_CONSTANT` only takes a single
	 * two-byte argument.
	 */
	public static final MAX_CONSTANTS = 1 << 16;

	/**
	 * The maximum distance a `CODE_JUMP` or `CODE_JUMP_IF` instruction can move the
	 * instruction pointer.
	 */
	public static final MAX_JUMP = 1 << 16;

	/**
	 * The maximum depth that interpolation can nest. For example, this string has
	 * three levels:
	 *
	 * ` "outside %(one + "%(two + "%(three)")")"`
	 */
	public static final MAX_INTERPOLATION_NESTING = 8;


	public static final GROW_FACTOR:Int = 2;

	public static final  MAP_LOAD_PERCENT= 75;

	public static final MIN_CAPACITY=16;

	/**
	 * The compiler for the function enclosing this one, or NULL if it's the
	 * top level.
	 */
	public var parent:Null<Compiler>;

	/**
	 * The currently in scope local variables.
	 */
	public var locals:FixedArray<Local> = new FixedArray(MAX_LOCALS);

	/**
	 * The number of local variables currently in scope.
	 */
	public var numLocals:Int;

	/**
	 * The upvalues that this function has captured from outer scopes. The count
	 * of them is stored in `[numUpvalues]`.
	 */
	public var upValues:FixedArray<CompilerUpvalue> = new FixedArray(MAX_UPVALUES);

	/**
	 * The current level of block scope nesting, where zero is no nesting. A -1
	 * here means top-level code is being compiled and there is no block scope
	 * in effect at all. Any variables declared will be module-level.
	 */
	public var scopeDepth:Int;

	/**
	 * The current number of slots (locals and temporaries) in use.
	 *
	 * We use this and maxSlots to track the maximum number of additional slots
	 * a function may need while executing. When the function is called, the
	 * fiber will check to ensure its stack has enough room to cover that worst
	 * case and grow the stack if needed.
	 *
	 * This value here doesn't include parameters to the function. Since those
	 * are already pushed onto the stack by the caller and tracked there, we
	 * don't need to double count them here.
	 */
	public var numSlots:Int;

	/**
	 * The current innermost loop being compiled, or NULL if not in a loop.
	 */
	public var loop:Null<Loop>;

	/**
	 * If this is a compiler for a method, keeps track of the class enclosing it.
	 */
	public var enclosingClass:ClassInfo;

	/**
	 * The function being compiled.
	 */
	public var fn:ObjFn;

	public var constants:ObjMap;

	public function error(msg:String) {
		var token = this.parser.last;
		this.parser.errors.push(SError(msg, token.pos, WrenLexer.lineCount - 1));

		var buf = new StringBuf();
		for (x in this.parser.errors) {
			switch x {
				case SError(msg, _, line):
					buf.add('[Line: ${line}] ${msg} \n');
				case _: continue;
			}
		}

		var module = this.parser.module.name;
		var moduleName = module != null ? module.value.join("") : "<unknown>";

		var message = buf.toString();

		this.parser.vm.config.errorFn(this.parser.vm, WREN_ERROR_COMPILE,
			moduleName, WrenLexer.lineCount - 1, message);
	}

	/**
	 * Adds [constant] to the constant pool and returns its index.
	 * @param constant
	 * @return Int
	 */
	public function addConstant(vm:VM, constant:Value):Int {
		if (this.parser.errors.length >= 1) {
			return -1;
		}

		// See if we already have a constant for the value. If so, reuse it.
		if (this.constants != null) {
			var exisiting:Value = constants.get(vm, constant);
			if (exisiting.IS_NUM())
				return FPHelper.floatToI32(exisiting.as.num);
		}

		// It's a new constant.
		if (this.fn.constants.count < MAX_CONSTANTS) {
			if (constant.IS_OBJ())
				this.parser.vm.pushRoot(constant.as.obj);
			fn.constants.write(constant);

			if (this.constants == null) {
				this.constants = new ObjMap(this.parser.vm);
			}

			this.constants.set(vm, constant, Value.NUM_VAL(fn.constants.count - 1));
		} else {
			error('A function may only contain ${MAX_CONSTANTS} unique constants.');
		}

		return this.fn.constants.count - 1;
	}

	function new() {}

	public static function init(parser:WrenParser, ?parent:Null<Compiler>, isMethod:Bool = false):Compiler {
		final compiler = new Compiler();
		compiler.parent = parent;
		compiler.parser = parser;
		compiler.loop = null;
		compiler.enclosingClass = null;

		// Initialize these to NULL before allocating in case a GC gets triggered in
		// the middle of initializing the compiler.
		compiler.fn = null;
		compiler.constants = null;

		compiler.parser.vm.compiler = compiler;

		// Declare a local slot for either the closure or method receiver so that we
		// don't try to reuse that slot for a user-defined local variable. For
		// methods, we name it "this", so that we can resolve references to that like
		// a normal variable. For functions, they have no explicit "this", so we use
		// an empty name. That way references to "this" inside a function walks up
		// the parent chain to find a method enclosing the function whose "this" we
		// can close over.

		compiler.numLocals = 1;
		compiler.numSlots = compiler.numLocals;

		if (isMethod) {
			compiler.locals[0].name = "this";
			compiler.locals[0].length = 4;
		} else {
			compiler.locals[0].name = null;
			compiler.locals[0].length = 0;
		}

		compiler.locals[0].depth = -1;
		compiler.locals[0].isUpvalue = false;

		if (parent == null) {
			// Compiling top-level code, so the initial scope is module-level.
			compiler.scopeDepth = -1;
		} else {
			// The initial scope for functions and methods is local scope.
			compiler.scopeDepth = 0;
		}

		compiler.fn = new ObjFn(compiler.parser.vm, parser.module, compiler.numLocals);

		return compiler;
	}

	/**
	 * Emits one single-byte argument. Returns its index.
	 * @param byte
	 */
	public function emitByte(byte:Int) {
		fn.code.write(byte);

		// Assume the instruction is associated with the most recently consumed token.
		fn.debug.sourceLines.write(WrenLexer.lineCount - 1);

		return fn.code.count - 1;
	}

	/**
	 * Emits one bytecode instruction.
	 * @param instruction
	 */
	public function emitOp(instruction:Code) {
		emitByte(instruction);
		this.numSlots += instruction.stackEffect();
		if (this.numSlots > this.fn.maxSlots) {
			this.fn.maxSlots = this.numSlots;
		}
	}

	/**
	 * Emits one 16-bit argument, which will be written big endian.
	 * @param arg
	 */
	public function emitShort(arg:Int) {
		emitByte((arg >> 8) & 0xff);
		emitByte(arg & 0xff);
	}

	/**
	 * Emits one bytecode instruction followed by a 8-bit argument. Returns the
	 * index of the argument in the bytecode.
	 * @param instr
	 * @param arg
	 */
	public function emitByteArg(instr:Code, arg:Int) {
		emitOp(instr);
		return emitByte(arg);
	}

	/**
	 * Emits one bytecode instruction followed by a 16-bit argument, which will be
	 * written big endian.
	 * @param instr
	 * @param arg
	 */
	public function emitShortArg(instr:Code, arg:Int) {
		emitOp(instr);
		return emitShort(arg);
	}

	/**
	 * Emits [instruction] followed by a placeholder for a jump offset. The
	 * placeholder can be patched by calling [jumpPatch]. Returns the index of the
	 * placeholder.
	 * @param instr
	 */
	public function emitJump(instr:Code) {
		emitOp(instr);
		emitByte(0xff);
		return emitByte(0xff) - 1;
	}

	/**
	 * Creates a new constant for the current value and emits the bytecode to load
	 * it from the constant table.
	 * @param value
	 */
	public function emitConstant(value:Value) {
		final constant = addConstant(this.parser.vm, value);
		// Compile the code to load the constant.
		emitShortArg(CODE_CONSTANT, constant);
	}

	/**
	 * Create a new local variable with [name]. Assumes the current scope is local
	 * and the name is unique.
	 * @param name
	 */
	public function addLocal(name:String) {
		final local = this.locals[this.numLocals];
		local.name = name;
		local.length = name.length;
		local.depth = this.scopeDepth;
		local.isUpvalue = false;
		return this.numLocals++;
	}

	/**
	 * Declares a variable in the current scope whose name is the given token.
	 *
	 * If [token] is `NULL`, uses the previously consumed token. Returns its symbol.
	 * @param token
	 */
	public function declareVariable(?token:Token) {
		if (token == null)
			token = this.parser.last;
		var length = token.pos.max - token.pos.min;
		if (length > MAX_VARIABLE_NAME) {
			error('Variable name cannot be longer than ${MAX_VARIABLE_NAME} characters.');
		}

		// Top-level module scope.
		if (this.scopeDepth == -1) {
			var line = -1;
			var symbol = this.parser.module.defineVariable(this.parser.vm, token.toString(), token.toString().length, Value.NULL_VAL(), line);

			if (symbol == -1) {
				error("Module variable is already defined.");
			} else if (symbol == -2) {
				error("Too many module variables defined.");
			} else if (symbol == -3) {
				error('Variable \'${token.toString()}\' referenced before this definition (first use at line $line).');
			}

			return symbol;
		}

		// See if there is already a variable with this name declared in the current
		// scope. (Outer scopes are OK: those get shadowed.)
		var i = this.numLocals - 1;
		while (i >= 0) {
			var local = this.locals[i];

			// Once we escape this scope and hit an outer one, we can stop.
			if (local.depth < this.scopeDepth)
				break;
			if (local.length == length && local.name == token.toString()) {
				error("Variable is already declared in this scope.");
				return i;
			}

			i--;
		}

		if (this.numLocals == MAX_LOCALS) {
			error('Cannot declare more than ${MAX_LOCALS} variables in one scope.');
			return -1;
		}

		return addLocal(token.toString());
	}

	public function declareNamedVariable() {
		return declareVariable();
	}

	/**
	 * Stores a variable with the previously defined symbol in the current scope.
	 * @param symbol
	 */
	public function defineVariable(symbol:Int) {
		// Store the variable. If it's a local, the result of the initializer is
		// in the correct slot on the stack already so we're done.
		if (this.scopeDepth >= 0)
			return;

		// It's a module-level variable, so store the value in the module slot and
		// then discard the temporary for the initializer.
		emitShortArg(CODE_STORE_MODULE_VAR, symbol);
		emitOp(CODE_POP);
	}

	public function pushScope() {
		this.scopeDepth++;
	}

	/**
	 * Generates code to discard local variables at [depth] or greater. Does *not*
	 * actually undeclare variables or pop any scopes, though. This is called
	 * directly when compiling "break" statements to ditch the local variables
	 * before jumping out of the loop even though they are still in scope *past*
	 * the break instruction
	 *
	 * Returns the number of local variables that were eliminated.
	 * @param depth
	 */
	public function discardLocals(depth:Int) {
		if (!(scopeDepth > -1)) {
			throw "Cannot exit top-level scope.";
		}

		var local = this.numLocals - 1;
		while (local >= 0 && this.locals[local].depth >= depth) {
			// If the local was closed over, make sure the upvalue gets closed when it
			// goes out of scope on the stack. We use emitByte() and not emitOp() here
			// because we don't want to track that stack effect of these pops since the
			// variables are still in scope after the break.
			if (this.locals[local].isUpvalue) {
				emitByte(CODE_CLOSE_UPVALUE);
			} else {
				emitByte(CODE_POP);
			}

			local--;
		}

		return this.numLocals - local - 1;
	}

	/**
	 * Closes the last pushed block scope and discards any local variables declared
	 * in that scope. This should only be called in a statement context where no
	 * temporaries are still on the stack.
	 */
	public function popScope() {
		var popped = discardLocals(scopeDepth);
		numLocals -= popped;
		numSlots -= popped;
		scopeDepth--;
	}

	/**
	 * Attempts to look up the name in the local variables of [compiler]. If found,
	 * returns its index, otherwise returns -1.
	 * @param name
	 */
	public function resolveLocal(name:String) {
		var i = this.numLocals - 1;
		while (i >= 0) {
			if (this.locals[i].length == name.length && this.locals[i].name == name) {
				return i;
			}
			i--;
		}

		return -1;
	}

	/**
	 * Adds an upvalue to [compiler]'s function with the given properties. Does not
	 * add one if an upvalue for that variable is already in the list. Returns the
	 * index of the upvalue.
	 * @param isLocal
	 * @param index
	 * @return Int
	 */
	public function addUpvalue(isLocal:Bool, index:Int):Int {
		// Look for an existing one.
		for (i in 0...this.fn.numUpvalues) {
			var upvalue:CompilerUpvalue = this.upValues[i];
			if (upvalue.index == index && upvalue.isLocal == isLocal)
				return i;
		}

		// If we got here, it's a new upvalue.
		this.upValues[this.fn.numUpvalues].isLocal = isLocal;
		this.upValues[this.fn.numUpvalues].index = index;
		return this.fn.numUpvalues++;
	}

	/**
	 * Attempts to look up [name] in the functions enclosing the one being compiled
	 * by [compiler]. If found, it adds an upvalue for it to this compiler's list
	 * of upvalues (unless it's already in there) and returns its index. If not
	 * found, returns -1.
	 *
	 * If the name is found outside of the immediately enclosing function, this
	 * will flatten the closure and add upvalues to all of the intermediate
	 * functions so that it gets walked down to this one.
	 *
	 * If it reaches a method boundary, this stops and returns -1 since methods do
	 * not close over local variables.
	 * @param name
	 */
	public function findUpvalue(name:String):Int {
		// If we are at the top level, we didn't find it.
		if (this.parent == null)
			return -1;

		// If we hit the method boundary (and the name isn't a static field), then
		// stop looking for it. We'll instead treat it as a self send.
		if (name.charAt(0) != '_' && this.parent.enclosingClass != null)
			return -1;

		// See if it's a local variable in the immediately enclosing function.
		var local = this.parent.resolveLocal(name);

		if (local != -1) {
			// Mark the local as an upvalue so we know to close it when it goes out of
			// scope.
			this.parent.locals[local].isUpvalue = true;

			return addUpvalue(true, local);
		}

		// See if it's an upvalue in the immediately enclosing function. In other
		// words, if it's a local variable in a non-immediately enclosing function.
		// This "flattens" closures automatically: it adds upvalues to all of the
		// intermediate functions to get from the function where a local is declared
		// all the way into the possibly deeply nested function that is closing over
		// it.
		var upvalue = findUpvalue(name);
		if (upvalue != -1) {
			return addUpvalue(false, upvalue);
		}

		// If we got here, we walked all the way up the parent chain and couldn't
		// find it.
		return -1;
	}

	/**
	 * Look up [name] in the current scope to see what variable it refers to.
	 * Returns the variable either in local scope, or the enclosing function's
	 * upvalue list. Does not search the module scope. Returns a variable with
	 * index -1 if not found.
	 * @param name
	 */
	public function resolveNonmodule(name:String):Variable {
		// Look it up in the local scopes.
		var variable:Variable = new Variable(resolveLocal(name), SCOPE_LOCAL);
		if (variable.index != -1)
			return variable;

		// Tt's not a local, so guess that it's an upvalue.
		variable.scope = SCOPE_UPVALUE;
		variable.index = findUpvalue(name);
		return variable;
	}

	/**
	 * Look up [name] in the current scope to see what variable it refers to.
	 * Returns the variable either in module scope, local scope, or the enclosing
	 * function's upvalue list. Returns a variable with index -1 if not found.
	 * @param name
	 */
	public function resolveName(name:String) {
		var variable:Variable = resolveNonmodule(name);
		if (variable.index != -1)
			return variable;

		variable.scope = SCOPE_MODULE;
		variable.index = this.parser.module.variableNames.find(name);
		return variable;
	}

	public function loadLocal(slot:Int) {
		if (slot <= 8) {
			emitOp(CODE_LOAD_LOCAL_0 + slot);
			return;
		}

		emitByteArg(CODE_LOAD_LOCAL, slot);
	}

	public function endCompiler(vm:VM, debugName:String) {
		if (this.parser.errors.length >= 1) {
			this.parser.vm.compiler = this.parent;
			return null;
		}

		// Mark the end of the bytecode. Since it may contain multiple early returns,
		// we can't rely on CODE_RETURN to tell us we're at the end.
		emitOp(CODE_END);

		this.fn.bindName(this.parser.vm, debugName);

		// In the function that contains this one, load the resulting function object.
		if (this.parent != null) {
			var constant = this.parent.addConstant(vm, this.fn.OBJ_VAL());

			// Wrap the function in a closure. We do this even if it has no upvalues so
			// that the VM can uniformly assume all called objects are closures. This
			// makes creating a function a little slower, but makes invoking them
			// faster. Given that functions are invoked more often than they are
			// created, this is a win.
			this.parent.emitShortArg(CODE_CLOSURE, constant);

			// Emit arguments for each upvalue to know whether to capture a local or
			// an upvalue.
			for (i in 0...this.fn.numUpvalues) {
				this.parent.emitByte(this.upValues[i].isLocal ? 1 : 0);
				this.parent.emitByte(this.upValues[i].index);
			}
		}
		// Pop this compiler off the stack.
		this.parser.vm.compiler =this.parent;

		#if WREN_DEBUG_DUMP_COMPILED_CODE
		this.parser.vm.dumpCode(this.fn);
		#end
		
		return this.fn;

	}

	/**
	 * Replaces the placeholder argument for a previous CODE_JUMP or CODE_JUMP_IF
	 * instruction with an offset that jumps to the current end of bytecode.
	 */
	public function patchJump(offset:Int) {
		// -2 to adjust for the bytecode for the jump offset itself.
		var jump = fn.code.count - offset - 2;
		if (jump > MAX_JUMP) error("Too much code to jump over.");

	
		this.fn.code.data[offset] =  (jump >> 8) & 0xff;
		
 		this.fn.code.data[offset + 1] = jump & 0xff;		
	}

	public function loadCoreVariable(name:String){}



	public static function compile(vm:VM, module:ObjModule, source:String, isExpression:Bool = false, printErrors:Bool = true):ObjFn {
	
		// Skip the UTF-8 BOM if there is one.
		// "\xEF\xBB\xBF"
		if(source.charCodeAt(0) == 239 && source.charCodeAt(1) == 187 && source.charCodeAt(2) == 191){
			source = source.substring(3);
		}

		var parser = new WrenParser(byte.ByteData.ofString(source), module.name.value.join(""));
		parser.vm = vm;
		parser.module = module;
		parser.source = source;

		var compiler = init(parser, null, false);
		// start parsing 
		parser.parse();

		compiler.emitOp(CODE_RETURN);

		return compiler.endCompiler(vm, "(script)");
	}


	/**
	 * Returns the number of arguments to the instruction at [ip] in [fn]'s
	 * bytecode.
	 * @param bytecode
	 * @param constants
	 * @param ip
	 * @return Int
	 */
	 public static function getByteCountForArguments(bytecode:Array<Int>, constants:Array<Value>, ip:Int):Int {
		var instruction:Code = bytecode[ip];
		return switch instruction {
			case CODE_NULL | CODE_FALSE | CODE_TRUE | CODE_POP | CODE_CLOSE_UPVALUE | CODE_RETURN | CODE_END | CODE_LOAD_LOCAL_0 | CODE_LOAD_LOCAL_1 |
				CODE_LOAD_LOCAL_2 | CODE_LOAD_LOCAL_3 | CODE_LOAD_LOCAL_4 | CODE_LOAD_LOCAL_5 | CODE_LOAD_LOCAL_6 | CODE_LOAD_LOCAL_7 | CODE_LOAD_LOCAL_8 |
				CODE_CONSTRUCT | CODE_FOREIGN_CONSTRUCT | CODE_FOREIGN_CLASS | CODE_END_MODULE:
				0;
			case CODE_LOAD_LOCAL | CODE_STORE_LOCAL | CODE_LOAD_UPVALUE | CODE_STORE_UPVALUE | CODE_LOAD_FIELD_THIS | CODE_STORE_FIELD_THIS |
				CODE_LOAD_FIELD | CODE_STORE_FIELD | CODE_CLASS:
				1;
			case CODE_CONSTANT | CODE_LOAD_MODULE_VAR | CODE_STORE_MODULE_VAR | CODE_CALL_0 | CODE_CALL_1 | CODE_CALL_2 | CODE_CALL_3 | CODE_CALL_4 | CODE_CALL_5 | CODE_CALL_6 | CODE_CALL_7 | CODE_CALL_8 |
				CODE_CALL_9 | CODE_CALL_10 | CODE_CALL_11 | CODE_CALL_12 | CODE_CALL_13 | CODE_CALL_14 | CODE_CALL_15 | CODE_CALL_16 | CODE_JUMP
				| CODE_LOOP | CODE_JUMP_IF | CODE_AND | CODE_OR | CODE_METHOD_INSTANCE | CODE_METHOD_STATIC | CODE_IMPORT_MODULE | CODE_IMPORT_VARIABLE: 2;
			case CODE_SUPER_0 | CODE_SUPER_1 | CODE_SUPER_2 | CODE_SUPER_3 | CODE_SUPER_4 | CODE_SUPER_5 | CODE_SUPER_6 | CODE_SUPER_7 | CODE_SUPER_8 |
				CODE_SUPER_9 | CODE_SUPER_10 | CODE_SUPER_11 | CODE_SUPER_12 | CODE_SUPER_13 | CODE_SUPER_14 | CODE_SUPER_15 | CODE_SUPER_16: 4;
			case CODE_CLOSURE:{
				var constant = (bytecode[ip + 1] << 8) | bytecode[ip + 2];
				var loadedFn:ObjFn = constants[constant].AS_FUN();
		  
				// There are two bytes for the constant, then two for each upvalue.
				return 2 + (loadedFn.numUpvalues * 2);
			}
		}
	}
}
