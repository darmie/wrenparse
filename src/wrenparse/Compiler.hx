package wrenparse;

import polygonal.ds.tools.mem.ByteMemory;
import haxe.io.UInt8Array;
import haxe.io.UInt16Array;
import haxe.io.Bytes;
import byte.ByteData;
import wrenparse.Data.Token;
import haxe.io.FPHelper;
import wrenparse.objects.*;
import wrenparse.Utils.FixedArray;
import wrenparse.IO.IntBuffer;
import wrenparse.IO.SymbolTable;
import wrenparse.Data;

using StringTools;

@:allow(wrenparse.Grammar)
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

	public static final MAP_LOAD_PERCENT = 75;

	public static final MIN_CAPACITY = 16;

	/**
	 * The compiler for the function enclosing this one, or NULL if it's the
	 * top level.
	 */
	public var parent:Null<Compiler>;

	/**
	 * The currently in scope local variables.
	 */
	public var locals:Array<Local>;

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

	var rules:GrammarRules;

	public function error(msg:String = "") {
		var token = this.parser.previous;
		// If the parse error was caused by an error token, the lexer has already
		// reported it.
		switch token.type {
			case TOKEN_ERROR:
				{
					return;
				}
			case TOKEN_LINE:
				{
					this.parser.printError(token.line, "Error at newline", msg);
				}
			case TOKEN_EOF:
				{
					this.parser.printError(token.line, "Error at end of file", msg);
				}
			case _:
				{
					var label:String = "";
					label += 'Error at \'${token.start}\'';
					this.parser.printError(token.line, label, msg);
				}
		}
	}

	/**
	 * Adds [constant] to the constant pool and returns its index.
	 * @param constant
	 * @return Int
	 */
	public function addConstant(constant:Value):Int {
		if (this.parser.hasError) {
			return -1;
		}

		// See if we already have a constant for the value. If so, reuse it.
		if (this.constants != null) {
			var exisiting:Value = constants.get(this.parser.vm, constant);
			if (exisiting.IS_NUM())
				return FPHelper.floatToI32(exisiting.as.num);
		}

		// It's a new constant.
		if (this.fn.constants.count < MAX_CONSTANTS) {
			if (constant.IS_OBJ())
				this.parser.vm.pushRoot(constant.AS_OBJ());
			fn.constants.write(constant);
			if (this.constants == null) {
				this.constants = new ObjMap(this.parser.vm);
			}

			this.constants.set(this.parser.vm, constant, Value.NUM_VAL(fn.constants.count - 1));
		} else {
			error('A function may only contain ${MAX_CONSTANTS} unique constants.');
		}

		return this.fn.constants.count - 1;
	}

	function new() {
		this.rules = new GrammarRules();
	}

	public static function init(parser:WrenParser, ?parent:Null<Compiler>, isMethod:Bool = false):Compiler {
		final compiler = new Compiler();
		compiler.parent = parent;
		compiler.parser = parser;
		compiler.loop = null;
		compiler.enclosingClass = {
			signature: {},
			staticMethods: new IntBuffer(parser.vm),
			methods: new IntBuffer(parser.vm),
			fields: new SymbolTable(parser.vm)
		};

		// Initialize these to NULL before allocating in case a GC gets triggered in
		// the middle of initializing the compiler.
		compiler.fn = null;
		compiler.constants = null;

		parser.vm.compiler = compiler;

		// Declare a local slot for either the closure or method receiver so that we
		// don't try to reuse that slot for a user-defined local variable. For
		// methods, we name it "this", so that we can resolve references to that like
		// a normal variable. For functions, they have no explicit "this", so we use
		// an empty name. That way references to "this" inside a function walks up
		// the parent chain to find a method enclosing the function whose "this" we
		// can close over.

		compiler.numLocals = 1;
		compiler.numSlots = compiler.numLocals;

		compiler.locals = [];
		compiler.locals[0] = {};
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

	// PARSING

	/**
	 * Returns the type of the current token.
	 * @return TokenType
	 */
	inline function peek():TokenType {
		return this.parser.current.type;
	}

	/**
	 * Consumes the current token if its type is [expected]. Returns true if a
	 * token was consumed.
	 * @param expected
	 * @return Bool
	 */
	inline function match(expected:TokenType):Bool {
		if (peek() != expected)
			return false;
		this.parser.nextToken();
		return true;
	}

	/**
	 * Consumes the current token. Emits an error if its type is not [expected].
	 * @param expected
	 * @param errorMessage
	 */
	function consume(expected:TokenType, errorMessage:String) {
		this.parser.nextToken();
		if (this.parser.previous.type != expected) {
			error(errorMessage);

			// If the next token is the one we want, assume the current one is just a
			// spurious error and discard it to minimize the number of cascaded errors.
			if (this.parser.current.type == expected)
				this.parser.nextToken();
		}
	}

	/**
	 * Matches one or more newlines. Returns true if at least one was found.
	 * @return Bool
	 */
	function matchLine():Bool {
		if (!match(TOKEN_LINE))
			return false;
		while (match(TOKEN_LINE)) {}
		return true;
	}

	/**
	 * Discards any newlines starting at the current token.
	 */
	function ignoreNewlines() {
		matchLine();
	}

	/**
	 * Consumes the current token. Emits an error if it is not a newline. Then
	 * discards any duplicate newlines following it.
	 * @param errorMessage
	 */
	function consumeLine(errorMessage:String) {
		consume(TOKEN_LINE, errorMessage);
		ignoreNewlines();
	}

	function getRule(type:TokenType):GrammarRule {
		return rules[type];
	}

	/**
	 * The main entrypoint for the top-down operator precedence parser.
	 * @param prec
	 */
	function parsePrecedence(precedence:Int) {
		this.parser.nextToken();
		var prefix = rules[this.parser.previous.type].prefix;
		if (prefix == null) {
			error("Expected expression.");
			return;
		}

		// Track if the precendence of the surrounding expression is low enough to
		// allow an assignment inside this one. We can't compile an assignment like
		// a normal expression because it requires us to handle the LHS specially --
		// it needs to be an lvalue, not an rvalue. So, for each of the kinds of
		// expressions that are valid lvalues -- names, subscripts, fields, etc. --
		// we pass in whether or not it appears in a context loose enough to allow
		// "=". If so, it will parse the "=" itself and handle it appropriately.
		var canAssign = precedence <= cast(PREC_CONDITIONAL, Int);

		prefix(this, canAssign);
		
		while (precedence <= cast(rules[this.parser.current.type].precedence, Int)) {
			this.parser.nextToken();
			var infix = rules[this.parser.previous.type].infix;
			infix(this, canAssign);
		}
	}

	function expression() {
		parsePrecedence(PREC_LOWEST);
	}

	/**
	 * Compiles a "definition". These are the statements that bind new variables.
	 * They can only appear at the top level of a block and are prohibited in places
	 * like the non-curly body of an if or while.
	 */
	function definition() {
	
		if (match(TOKEN_CLASS)) {
			classDefinition(false);
		} else if (match(TOKEN_FOREIGN)) {
			consume(TOKEN_CLASS, "Expect 'class' after 'foreign'.");
			classDefinition(true);
		} else if (match(TOKEN_IMPORT)) {
			import_();
		} else if (match(TOKEN_VAR)) {
			variableDefinition();
		} else {
			statement();
		}
	}

	/**
	 * Compiles a class definition. Assumes the "class" token has already been
	 * consumed (along with a possibly preceding "foreign" token).
	 * @param isForeign
	 */
	function classDefinition(isForeign:Bool) {
		// Create a variable to store the class in.
		var classVariable:Variable = new Variable(declareNamedVariable(), this.scopeDepth == -1 ? SCOPE_MODULE : SCOPE_LOCAL);

		// Create shared class name value
		var classNameString:Value = ObjString.newString(this.parser.vm, this.parser.previous.start);

		// Create class name string to track method duplicates
		var className:ObjString = classNameString.AS_STRING();

		// Make a string constant for the name.
		emitConstant(classNameString);
	

		// Load the superclass (if there is one).
		if (match(TOKEN_IS)) {
			parsePrecedence(PREC_CALL);
		} else {
			// Implicitly inherit from Object.
			loadCoreVariable("Object");
		}

		// Store a placeholder for the number of fields argument. We don't know the
		// count until we've compiled all the methods to see which fields are used.

		var numFieldsInstruction = -1;
		if (isForeign) {
			emitOp(CODE_FOREIGN_CLASS);
		} else {
			numFieldsInstruction = emitByteArg(CODE_CLASS, 255);
		}

		// Store it in its name.
		defineVariable(classVariable.index);

		// Push a local variable scope. Static fields in a class body are hoisted out
		// into local variables declared in this scope. Methods that use them will
		// have upvalues referencing them.
		pushScope();

		var classInfo:ClassInfo = {
			isForeign: isForeign,
			name: className
		};
		
		// Set up a symbol table for the class's fields. We'll initially compile
		// them to slots starting at zero. When the method is bound to the class, the
		// bytecode will be adjusted by [wrenBindMethod] to take inherited fields
		// into account.
		classInfo.fields = new SymbolTable(this.parser.vm);

		// Set up symbol buffers to track duplicate static and instance methods.
		classInfo.methods = new IntBuffer(this.parser.vm);
		classInfo.staticMethods = new IntBuffer(this.parser.vm);
		this.enclosingClass = classInfo;

		
		// Compile the method definitions.
		consume(TOKEN_LEFT_BRACE, "Expect '{' after class declaration.");
		matchLine();
		while (!match(TOKEN_RIGHT_BRACE)) {
			if (!method(classVariable))
				break;
			
			// Don't require a newline after the last definition.
			if (match(TOKEN_RIGHT_BRACE))
				break;

			consumeLine("Expect newline after definition in class.");
		}

		// Update the class with the number of fields.
		if (!isForeign) {
			this.fn.code.data.set(numFieldsInstruction, classInfo.fields.count);
		}

		// Clear symbol tables for tracking field and method names.
		classInfo.fields.clear();
		classInfo.methods.clear();
		classInfo.staticMethods.clear();
		this.enclosingClass = null;
		popScope();
	}

	/**
	 * Compiles a "var" variable definition statement.
	 */
	function variableDefinition() {
		// Grab its name, but don't declare it yet. A (local) variable shouldn't be
		// in scope in its own initializer.
		consume(TOKEN_NAME, "Expect variable name.");
		var nameToken = this.parser.previous;
		
		// Compile the initializer.
		if (match(TOKEN_EQ)) {
			ignoreNewlines();
			expression();
		} else {
			// Default initialize it to null.
			Grammar.null_(this, false);
		}
		// Now put it in scope.
		var symbol = declareVariable(nameToken);
		defineVariable(symbol);
	}

	/**
	 * Compiles an "import" statement.
	 *
	 * An import compiles to a series of instructions. Given:
	 *
	 * 		import "foo" for Bar, Baz
	 *
	 * We compile a single IMPORT_MODULE "foo" instruction to load the module
	 * itself. When that finishes executing the imported module, it leaves the
	 * ObjModule in vm.lastModule. Then, for Bar and Baz, we:
	 *
	 * * Declare a variable in the current scope with that name.
	 * * Emit an IMPORT_VARIABLE instruction to load the variable's value from the
	 * 	 other module.
	 * * Compile the code to store that value in the variable in this scope.
	 */
	function import_() {
		ignoreNewlines();
		consume(TOKEN_STRING, "Expect a string after 'import'.");
		var moduleConstant = addConstant(this.parser.previous.value);

		// Load the module.
		emitShortArg(CODE_IMPORT_MODULE, moduleConstant);

		// Discard the unused result value from calling the module body's closure.
		emitOp(CODE_POP);

		// The for clause is optional.
		if (!match(TOKEN_FOR))
			return;

		// Compile the comma-separated list of variables to import.
		do {
			ignoreNewlines();
			var slot = declareNamedVariable();

			// Define a string constant for the variable name.
			var variableConstant = addConstant(ObjString.newString(this.parser.vm, this.parser.previous.start));

			// Load the variable from the other module.
			emitShortArg(CODE_IMPORT_VARIABLE, variableConstant);

			// Store the result in the variable here.
			defineVariable(slot);
		} while (match(TOKEN_COMMA));
	}

	/**
	 * Compiles a method definition inside a class body.
	 *
	 * Returns `true` if it compiled successfully, or `false` if the method couldn't
	 * be parsed.
	 * @param classVariable
	 */
	function method(classVariable:Variable) {
		// TODO: What about foreign constructors?
		var isForeign = match(TOKEN_FOREIGN);
		var isStatic = match(TOKEN_STATIC);
		this.enclosingClass.inStatic = isStatic;
		var signatureFn = rules[this.parser.current.type].method;

		this.parser.nextToken();

		if (signatureFn == null) {
			error("Expect method definition.");
			return false;
		}

		// Build the method signature.
		var signature = signatureFromToken(SIG_GETTER);


		this.enclosingClass.signature = signature;


		var methodCompiler:Compiler = init(this.parser, this, true);

		// Compile the method signature.
		signatureFn(methodCompiler, signature);

		if (isStatic && signature.type == SIG_INITIALIZER) {
			error("A constructor cannot be static.");
		}
		
		// Include the full signature in debug messages in stack traces.
		var fullSignature:String = signature.toString();
		
		// Check for duplicate methods. Doesn't matter that it's already been
		// defined, error will discard bytecode anyway.
		// Check if the method table already contains this symbol
		// trace(fullSignature.toString());
		var methodSymbol = declareMethod(signature, fullSignature);

		if (isForeign) {
			// Define a constant for the signature.
			emitConstant(ObjString.newString(this.parser.vm, fullSignature));

			// We don't need the function we started compiling in the parameter list
			// any more.
			methodCompiler.parser.vm.compiler = methodCompiler.parent;
		} else {
			this.consume(TOKEN_LEFT_BRACE, "Expect '{' to begin method body.");
			Grammar.finishBody(methodCompiler, signature.type == SIG_INITIALIZER);
			methodCompiler.endCompiler(fullSignature);
		}

		// Define the method. For a constructor, this defines the instance
		// initializer method.
		this.defineMethod(classVariable, isStatic, methodSymbol);

		if (signature.type == SIG_INITIALIZER) {
			// Also define a matching constructor method on the metaclass.
			signature.type = SIG_METHOD;
			var constructorSymbol = this.signatureSymbol(signature);

			createConstructor(signature, methodSymbol);
			this.defineMethod(classVariable, true, constructorSymbol);
		}

		return true;
	}

	/**
	 * Compiles a simple statement. These can only appear at the top-level or
	 * within curly blocks. Simple statements exclude variable binding statements
	 * like "var" and "class" which are not allowed directly in places like the
	 * branches of an "if" statement.
	 *
	 * Unlike expressions, statements do not leave a value on the stack.
	 */
	function statement() {
		
		if (match(TOKEN_BREAK)) {
			if (this.loop == null) {
				error("Cannot use 'break' outside of a loop.");
				return;
			}

			// Since we will be jumping out of the scope, make sure any locals in it
			// are discarded first.
			discardLocals(this.loop.scopeDepth + 1);

			// Emit a placeholder instruction for the jump to the end of the body. When
			// we're done compiling the loop body and know where the end is, we'll
			// replace these with `CODE_JUMP` instructions with appropriate offsets.
			// We use `CODE_END` here because that can't occur in the middle of
			// bytecode.
			emitJump(CODE_END);
		} else if (match(TOKEN_FOR)) {
			forStatement();
		} else if (match(TOKEN_IF)) {
			ifStatement();
		} else if (match(TOKEN_RETURN)) {
			// Compile the return value.
			if (peek() == TOKEN_LINE) {
				// Implicitly return null if there is no value.
				emitOp(CODE_NULL);
			} else {
				expression();
			}

			emitOp(CODE_RETURN);
		} else if (match(TOKEN_WHILE)) {
			whileStatement();
		} else if (match(TOKEN_LEFT_BRACE)) {
			// Block statement.
			pushScope();
			if (Grammar.finishBlock(this)) {
				// Block was an expression, so discard it.
				emitOp(CODE_POP);
			}
			popScope();
		} else {
			// Expression statement.
			expression();
			emitOp(CODE_POP);
		}
	}

	inline function forStatement() {
		// A for statement like:
		//
		//     for (i in sequence.expression) {
		//       System.print(i)
		//     }
		//
		// Is compiled to bytecode almost as if the source looked like this:
		//
		//     {
		//       var seq_ = sequence.expression
		//       var iter_
		//       while (iter_ = seq_.iterate(iter_)) {
		//         var i = seq_.iteratorValue(iter_)
		//         System.print(i)
		//       }
		//     }
		//
		// It's not exactly this, because the synthetic variables `seq_` and `iter_`
		// actually get names that aren't valid Wren identfiers, but that's the basic
		// idea.
		//
		// The important parts are:
		// - The sequence expression is only evaluated once.
		// - The .iterate() method is used to advance the iterator and determine if
		//   it should exit the loop.
		// - The .iteratorValue() method is used to get the value at the current
		//   iterator position.

		// Create a scope for the hidden local variables used for the iterator.
		pushScope();
		consume(TOKEN_LEFT_PAREN, "Expect '(' after 'for'.");
		consume(TOKEN_NAME, "Expect for loop variable name.");

		// Remember the name of the loop variable.
		var name = this.parser.previous.start;
		consume(TOKEN_IN, "Expect 'in' after loop variable.");
		ignoreNewlines();
		// Evaluate the sequence expression and store it in a hidden local variable.
		// The space in the variable name ensures it won't collide with a user-defined
		// variable.
		expression();
		
		// Verify that there is space to hidden local variables.
		// Note that we expect only two addLocal calls next to each other in the
		// following code.

		if (this.numLocals + 2 > MAX_LOCALS) {
			error('Cannot declare more than $MAX_LOCALS variables in one scope. (Not enough space for for-loops internal variables)');
			return;
		}
		var seqSlot = addLocal("seq ");
		// Create another hidden local for the iterator object.
		Grammar.null_(this, false);
		var iterSlot = addLocal("iter ");
		consume(TOKEN_RIGHT_PAREN, "Expect ')' after loop expression.");
		var loop = {};
		startLoop(loop);

		// Advance the iterator by calling the ".iterate" method on the sequence.
		loadLocal(seqSlot);
		loadLocal(iterSlot);

		// Update and test the iterator.
		callMethod(1, "iterate(_)");
		emitByteArg(CODE_STORE_LOCAL, iterSlot);
		testExitLoop();

		// Get the current value in the sequence by calling ".iteratorValue".
		loadLocal(seqSlot);
		loadLocal(iterSlot);
		callMethod(1, "iteratorValue(_)");

		// Bind the loop variable in its own scope. This ensures we get a fresh
		// variable each iteration so that closures for it don't all see the same one.
		pushScope();
		addLocal(name);

		loopBody();

		// Loop variable.
		popScope();

		endLoop();
		// Hidden variables.
		popScope();
	}

	inline function ifStatement() {
		// Compile the condition.
		consume(TOKEN_LEFT_PAREN, "Expect '(' after 'if'.");
		expression();
		consume(TOKEN_RIGHT_PAREN, "Expect ')' after if condition.");
		
		// Jump to the else branch if the condition is false.
		var ifJump = emitJump(CODE_JUMP_IF);
		// Compile the then branch.
		statement();
		
		// Compile the else branch if there is one.
		if (match(TOKEN_ELSE)) {
			// Jump over the else branch when the if branch is taken.
			var elseJump = emitJump(CODE_JUMP);
			patchJump(ifJump);

			statement();

			// Patch the jump over the else.
			patchJump(elseJump);
		} else {
			patchJump(ifJump);
		}
	}

	inline function whileStatement() {
		var loop = {};
		startLoop(loop);
		// Compile the condition.
		consume(TOKEN_LEFT_PAREN, "Expect '(' after 'while'.");
		expression();
		consume(TOKEN_RIGHT_PAREN, "Expect ')' after while condition.");

		testExitLoop();
		loopBody();
		endLoop();
	}

	// Variables and scopes --------------------------------------------------------

	/**
	 * Emits one single-byte argument. Returns its index.
	 * @param byte
	 */
	public function emitByte(byte:Int) {
		fn.code.write(byte);
		// Assume the instruction is associated with the most recently consumed token.
		fn.debug.sourceLines.write(this.parser.previous.line);

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
		
		var off = (arg >> 8) & 0xff;
		var val = arg & 0xff;

		emitByte(off);
		emitByte(val);
	}

	/**
	 * Emits one bytecode instruction followed by a 8-bit argument. Returns the
	 * index of the argument in the bytecode.
	 * @param instr
	 * @param arg
	 */
	public function emitByteArg(instr:Code, arg:Int):Int {
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
		emitShort(arg);
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
		final constant = addConstant(value);
		// Compile the code to load the constant.
		emitShortArg(CODE_CONSTANT, constant);
	}

	/**
	 * Create a new local variable with [name]. Assumes the current scope is local
	 * and the name is unique.
	 * @param name
	 */
	public function addLocal(name:String) {
		var local:Local = {};
		local.name = name;
		local.length = name.length;
		local.depth = this.scopeDepth;
		local.isUpvalue = false;
		this.locals.push(local);
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
			token = this.parser.previous;
		
		var length = token.start.length;
		if (length > MAX_VARIABLE_NAME) {
			error('Variable name cannot be longer than ${MAX_VARIABLE_NAME} characters.');
		}


		// Top-level module scope.
		if (this.scopeDepth == -1) {
			var line = -1;
			var symbol = this.parser.module.defineVariable(this.parser.vm, token.start, Value.NULL_VAL(), line);
			
			if (symbol == -1) {
				error("Module variable is already defined.");
			} else if (symbol == -2) {
				error("Too many module variables defined.");
			} else if (symbol == -3) {
				error('Variable \'${token.start}\' referenced before this definition (first use at line $line).');
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
			if (local.length == length && local.name == token.start) {
				error("Variable is already declared in this scope.");
				return i;
			}
			i--;
		}

		if (this.numLocals == MAX_LOCALS) {
			error('Cannot declare more than ${MAX_LOCALS} variables in one scope.');
			return -1;
		}
		
		return addLocal(token.start);
	}

	/**
	 * Parses a name token and declares a variable in the current scope with that
	 * name. Returns its slot.
	 */
	public function declareNamedVariable() {
		consume(TOKEN_NAME, "Expect variable name.");
		return declareVariable();
	}

	/**
	 * Declares a method in the enclosing class with [signature].
	 *
	 * Reports an error if a method with that signature is already declared.
	 * Returns the symbol for the method.
	 * @param signature
	 * @param name
	 */
	public function declareMethod(signature:Signature, name:String) {
		var symbol = signatureSymbol(signature);

		// See if the class has already declared method with this signature.
		var classInfo = this.enclosingClass;
		var methods = classInfo.inStatic ? classInfo.staticMethods : classInfo.methods;

		for (i in 0...methods.count) {
			if (methods.data[i] == symbol) {
				var staticPrefix = classInfo.inStatic ? "static " : "";
				error('Class ${classInfo.name.value.join("")} already defines a ${staticPrefix}method \'${name}\'.');
			}
		}

		methods.write(symbol);
		return symbol;
	}

	public function defineMethod(classVariable:Variable, isStatic:Bool, symbol:Int) {
		// Load the class. We have to do this for each method because we can't
		// keep the class on top of the stack. If there are static fields, they
		// will be locals above the initial variable slot for the class on the
		// stack. To skip past those, we just load the class each time right before
		// defining a method.
		loadVariable(classVariable);

		// Define the method.
		var instruction:Code = isStatic ? CODE_METHOD_STATIC : CODE_METHOD_INSTANCE;
		emitShortArg(instruction, symbol);
	}

	/**
	 * Creates a matching constructor method for an initializer with [signature]
	 * and [initializerSymbol].
	 *
	 * Construction is a two-stage process in Wren that involves two separate
	 * methods. There is a static method that allocates a new instance of the class.
	 *
	 * It then invokes an initializer method on the new instance, forwarding all of
	 * the constructor arguments to it.
	 *
	 * The allocator method always has a fixed implementation:
	 *
	 * 		CODE_CONSTRUCT - Replace the class in slot 0 with a new instance of it.
	 * 		CODE_CALL      - Invoke the initializer on the new instance.
	 *
	 * This creates that method and calls the initializer with [initializerSymbol].
	 * @param signature
	 * @param initializerSymbold
	 */
	function createConstructor(signature:Signature, initializerSymbol) {
		var methodCompiler = init(this.parser, this, true);

		// Allocate the instance.
		methodCompiler.emitOp(this.enclosingClass.isForeign ? CODE_FOREIGN_CONSTRUCT : CODE_CONSTRUCT);

		// Run its initializer.
		methodCompiler.emitShortArg(CODE_CALL_0 + signature.arity, initializerSymbol);

		// Return the instance.
		methodCompiler.emitOp(CODE_RETURN);

		methodCompiler.endCompiler("");
	}

	/**
	 * Gets the symbol for a method with [signature].
	 * @param signature
	 */
	public function signatureSymbol(signature:Signature) {
		var name = signature.toString();
		return methodSymbol(name);
	}

	/**
	 * Gets the symbol for a method [name] with [length].
	 * @param name
	 */
	public function methodSymbol(name:String) {
		return this.parser.vm.methodNames.ensure(name);
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
			error("Cannot exit top-level scope.");
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

	/**
	 * Emits the code to load [variable] onto the stack.
	 * @param variable
	 */
	public function loadVariable(variable:Variable) {
		switch (variable.scope) {
			case SCOPE_LOCAL:
				loadLocal(variable.index);
			case SCOPE_UPVALUE:
				emitByteArg(CODE_LOAD_UPVALUE, variable.index);
			case SCOPE_MODULE:
				emitShortArg(CODE_LOAD_MODULE_VAR, variable.index);
		}
	}

	/**
	 * Loads the receiver of the currently enclosing method. Correctly handles
	 * functions defined inside methods.
	 */
	public function loadThis() {
		loadVariable(resolveNonmodule("this"));
	}

	public function endCompiler(debugName:String) {
		if (this.parser.hasError) {
			this.parser.vm.compiler = this.parent;
			return null;
		}

		// Mark the end of the bytecode. Since it may contain multiple early returns,
		// we can't rely on CODE_RETURN to tell us we're at the end.
		emitOp(CODE_END);

		this.fn.bindName(this.parser.vm, debugName);

		// In the function that contains this one, load the resulting function object.
		if (this.parent != null) {
			var constant = this.parent.addConstant(this.fn.OBJ_VAL());

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
		this.parser.vm.compiler = this.parent;

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
		if (jump > MAX_JUMP)
			error("Too much code to jump over.");

		this.fn.code.data.set(offset, (jump >> 8) & 0xff);

		this.fn.code.data.set(offset + 1, jump & 0xff);
	}

	public function loadCoreVariable(name:String) {
		var symbol = this.parser.module.variableNames.find(name);
		Utils.ASSERT(symbol != -1, "Should have already defined core name.");
		emitShortArg(CODE_LOAD_MODULE_VAR, symbol);
	}

	public static function compile(vm:VM, module:ObjModule, source:String, isExpression:Bool = false, printErrors:Bool = true):ObjFn {
		// Skip the UTF-8 BOM if there is one.
		// "\xEF\xBB\xBF"
		if (source.charCodeAt(0) == 239 && source.charCodeAt(1) == 187 && source.charCodeAt(2) == 191) {
			source = source.substring(3);
		}
		var parser = new WrenParser(null, module.name != null ? module.name.value.join("") : null);
		parser.vm = vm;
		parser.module = module;
		parser.source = source;

		parser.tokenStart = source;
		parser.currentChar =  source;
		parser.currentLine = 1;
		parser.numParens = 0;

		// Zero-init the current token. This will get copied to previous when
		// advance() is called below.
		parser.current.type = TOKEN_ERROR;
		parser.current.start = "";
		parser.current.length = 0;
		parser.current.line = 0;
		parser.current.value = Value.UNDEFINED_VAL();

		// Ignore leading newlines.
		parser.skipNewLines = true;
		parser.printErrors = printErrors;
		parser.hasError = false;

		// Read the first token.
		parser.nextToken();

		var numExistingVariables = module.variables.count;

		var compiler = init(parser, null, false);

		compiler.ignoreNewlines();

		if (isExpression) {
			compiler.expression();
			compiler.consume(TOKEN_EOF, "Expect end of expression.");
		} else {
			while (!compiler.match(TOKEN_EOF)) {
				compiler.definition();

				// If there is no newline, it must be the end of file on the same line.
				if (!compiler.matchLine()) {
					compiler.consume(TOKEN_EOF, "Expect end of file.");
					break;
				}
			}

			compiler.emitOp(CODE_END_MODULE);
		}

		compiler.emitOp(CODE_RETURN);

		// See if there are any implicitly declared module-level variables that never
		// got an explicit definition. They will have values that are numbers
		// indicating the line where the variable was first used.
		
		for (i in numExistingVariables...parser.module.variables.count) {
			if (parser.module.variables.data[i].IS_NUM()) {
				// Synthesize a token for the original use site.
				parser.previous.type = TOKEN_NAME;
				parser.previous.start = parser.module.variableNames.data[i].value.join("");
				parser.previous.length = parser.module.variableNames.data[i].length;
				parser.previous.line = Std.int(parser.module.variables.data[i].AS_NUM());
				compiler.error("Variable is used but not defined.");
			}
		}

		return compiler.endCompiler("(script)");
	}

	/**
	 * Returns the number of arguments to the instruction at [ip] in [fn]'s
	 * bytecode.
	 * @param bytecode
	 * @param constants
	 * @param ip
	 * @return Int
	 */
	public static function getByteCountForArguments(bytecode:ByteMemory, constants:Array<Value>, ip:Int):Int {
		var instruction:Code = bytecode.get(ip);
		return switch instruction {
			case CODE_NULL | CODE_FALSE | CODE_TRUE | CODE_POP | CODE_CLOSE_UPVALUE | CODE_RETURN | CODE_END | CODE_LOAD_LOCAL_0 | CODE_LOAD_LOCAL_1 |
				CODE_LOAD_LOCAL_2 | CODE_LOAD_LOCAL_3 | CODE_LOAD_LOCAL_4 | CODE_LOAD_LOCAL_5 | CODE_LOAD_LOCAL_6 | CODE_LOAD_LOCAL_7 | CODE_LOAD_LOCAL_8 |
				CODE_CONSTRUCT | CODE_FOREIGN_CONSTRUCT | CODE_FOREIGN_CLASS | CODE_END_MODULE:
				0;
			case CODE_LOAD_LOCAL | CODE_STORE_LOCAL | CODE_LOAD_UPVALUE | CODE_STORE_UPVALUE | CODE_LOAD_FIELD_THIS | CODE_STORE_FIELD_THIS |
				CODE_LOAD_FIELD | CODE_STORE_FIELD | CODE_CLASS:
				1;
			case CODE_CONSTANT | CODE_LOAD_MODULE_VAR | CODE_STORE_MODULE_VAR | CODE_CALL_0 | CODE_CALL_1 | CODE_CALL_2 | CODE_CALL_3 | CODE_CALL_4 |
				CODE_CALL_5 | CODE_CALL_6 | CODE_CALL_7 | CODE_CALL_8 | CODE_CALL_9 | CODE_CALL_10 | CODE_CALL_11 | CODE_CALL_12 | CODE_CALL_13 |
				CODE_CALL_14 | CODE_CALL_15 | CODE_CALL_16 | CODE_JUMP | CODE_LOOP | CODE_JUMP_IF | CODE_AND | CODE_OR | CODE_METHOD_INSTANCE |
				CODE_METHOD_STATIC | CODE_IMPORT_MODULE | CODE_IMPORT_VARIABLE: 2;
			case CODE_SUPER_0 | CODE_SUPER_1 | CODE_SUPER_2 | CODE_SUPER_3 | CODE_SUPER_4 | CODE_SUPER_5 | CODE_SUPER_6 | CODE_SUPER_7 | CODE_SUPER_8 |
				CODE_SUPER_9 | CODE_SUPER_10 | CODE_SUPER_11 | CODE_SUPER_12 | CODE_SUPER_13 | CODE_SUPER_14 | CODE_SUPER_15 | CODE_SUPER_16: 4;
			case CODE_CLOSURE: {
					var constant = (bytecode.get(ip + 1) << 8) | bytecode.get(ip + 2);
					var loadedFn:ObjFn = constants[constant].AS_FUN();

					// There are two bytes for the constant, then two for each upvalue.
					return 2 + (loadedFn.numUpvalues * 2);
				}
		}
	}

	public function signatureFromToken(type:SignatureType) {
		var signature:Signature = {};
		// Get the token for the method name.
		var token = this.parser.previous;
		signature.name = token.start;
		signature.length = token.start.length;
		signature.type = type;
		signature.arity = 0;
	
		if (signature.length > MAX_METHOD_NAME) {
			error('Method names cannot be longer than $MAX_METHOD_NAME characters.');
			signature.length = MAX_METHOD_NAME;
		}
		
		return signature;
	}

	public function validateNumParameters(numArgs:Int) {
		if (numArgs == MAX_PARAMETERS + 1) {
			// Only show an error at exactly max + 1 so that we can keep parsing the
			// parameters and minimize cascaded errors.
			error('Methods cannot have more than ${MAX_PARAMETERS} parameters.');
		}
	}

	public function startLoop(loop:Loop) {
		loop.enclosing = this.loop;
		loop.start = this.fn.code.count - 1;
		loop.scopeDepth = this.scopeDepth;
		this.loop = loop;
	}

	/**
	 * Ends the current innermost loop. Patches up all jumps and breaks now that
	 * we know where the end of the loop is.
	 *
	 */
	public function endLoop() {
		// We don't check for overflow here since the forward jump over the loop body
		// will report an error for the same problem.
		var loopOffset = this.fn.code.count - this.loop.start + 2;
		emitShortArg(CODE_LOOP, loopOffset);
		patchJump(this.loop.exitJump);
		// Find any break placeholder instructions (which will be CODE_END in the
		// bytecode) and replace them with real jumps.
		var i = this.loop.body;
		while (i < this.fn.code.count) {
			if (this.fn.code.data.get(i) == CODE_END) {
				this.fn.code.data.set(i, CODE_JUMP);
				patchJump(i + 1);
				i += 3;
			} else {
				// Skip this instruction and its arguments.
				i += 1 + getByteCountForArguments(this.fn.code.data, this.fn.constants.data, i);
			}
		}
		this.loop = this.loop.enclosing;
	}

	public function testExitLoop() {
		this.loop.exitJump = emitJump(CODE_JUMP_IF);
	}

	public function loopBody() {
		this.loop.body = this.fn.code.count;
		statement();
	}

	public static function isLocalName(name:String):Bool {
		return Utils.isLocalName(name);
	}

	inline function callMethod(numArgs:Int, name:String) {
		var symbol = methodSymbol(name);
		emitShortArg(cast(CODE_CALL_0 + numArgs, Code), symbol);
	}

	inline function callSignature(instruction:Code, signature:Signature) {
		var symbol = signatureSymbol(signature);
		emitShortArg(cast(instruction + signature.arity, Code), symbol);
		if (instruction == CODE_SUPER_0) {
			// Super calls need to be statically bound to the class's superclass. This
			// ensures we call the right method even when a method containing a super
			// call is inherited by another subclass.
			//
			// We bind it at class definition time by storing a reference to the
			// superclass in a constant. So, here, we create a slot in the constant
			// table and store NULL in it. When the method is bound, we'll look up the
			// superclass then and store it in the constant slot.
			emitShort(addConstant(Value.NULL_VAL()));
		}
	}
}
