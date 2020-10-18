package wrenparse;

import hxparse.NoMatch;
import wrenparse.IO.IntBuffer;
import wrenparse.objects.ObjClass.MethodBuffer;
import wrenparse.objects.ObjClass.Method;
import wrenparse.IO.SymbolTable;
import wrenparse.Compiler.ClassInfo;
import wrenparse.Compiler.Loop;
import wrenparse.Compiler.Signature;
import wrenparse.Compiler.SignatureType;
import wrenparse.Compiler.Code;
import wrenparse.objects.ObjModule;
import haxe.macro.Expr;
import wrenparse.Data;
import hxparse.Parser.parse as parse;
import wrenparse.Compiler.Variable;
import wrenparse.objects.*;

enum ParserErrorMsg {
	DuplicateDefault;
	Unimplemented;
	Custom(s:String);
}

class ParserError {
	public var msg:ParserErrorMsg;
	public var pos:Position;

	public function new(message:ParserErrorMsg, pos:Position) {
		this.msg = message;
		this.pos = pos;
	}
}

abstract Statement(StatementDef) from StatementDef to StatementDef {
	public inline function emit() {
		// Todo: evaluate and emit bytecode
		return this;
	}
	// public inline function toString(){
	// 	return switch this {
	// 		case SError(msg, pos, line):{
	// 			return '[Line: $line] $msg';
	// 		}
	// 		case _: "";
	// 	}
	// }
}

class WrenParser extends hxparse.Parser<hxparse.LexerTokenSource<Token>, Token> implements hxparse.ParserBuilder {
	public var source:String;
	public var errors:Array<Statement> = [];

	public var vm:VM;
	public var module:ObjModule;

	public function new(input:byte.ByteData, sourceName:String = "main") {
		source = sourceName;
		var lexer = new WrenLexer(input, sourceName);
		var ts = new hxparse.LexerTokenSource(lexer, WrenLexer.tok);
		super(ts);
	}

	public inline function parse():Array<Statement> {
		var ret = parseRepeat(parseStatements);
		if (errors.length > 0) {
			return errors;
		}
		#if WREN_COMPILE
		vm.compiler.emitOp(CODE_END_MODULE);
		#end
		return ret;
	}

	function parseStatements():Statement {
		return switch stream {
			case [{tok: Eof}]: throw new hxparse.NoMatch<Dynamic>(curPos(), peek(0));
			case [{tok: Line}]: parseStatements();
			case [{tok: Comment(s)}]: parseStatements();
			case [{tok: CommentLine(s)}]: parseStatements();
			case [importStmt = parseImport()]: importStmt;
			case [classStmt = parseClass()]: classStmt;
			case [{tok: Kwd(KwdForeign)}, classStmt = parseClass(true)]: classStmt;
			case [{tok: Kwd(KwdVar)}, variable = variableDecl()]: SExpression(variable, variable.pos);
			case [controlFlowStmt = parseControlFlow()]: controlFlowStmt;
			case [{tok: BrOpen, pos: p}]: {
					#if WREN_COMPILE
					this.vm.compiler.pushScope();
					if (peek(0).tok == Line) { // single line expression?
						this.vm.compiler.emitOp(CODE_POP);
					}
					#end
					var stmt = parseRepeat(parseStatements);
					#if WREN_COMPILE
					this.vm.compiler.popScope();
					#end
					switch stream {
						case [{tok: BrClose}, {tok: Line}]: SBlock(stmt);
						case _:
							errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' ', p, WrenLexer.lineCount));
							null;
					}
				}
			case [{tok: Kwd(KwdReturn), pos: p}]:
				switch stream {
					case [exp = parseExpression()]: {
							#if WREN_COMPILE
							this.vm.compiler.emitOp(CODE_RETURN);
							#end
							SExpression({expr: EReturn(exp), pos: exp.pos}, exp.pos);
						}
					case [{tok: Eof}]:
						errors.push(SError('Error at \'${peek(0)}\': Expected expression.', p, WrenLexer.lineCount));
						null;
					case _: {
							#if WREN_COMPILE
							this.vm.compiler.emitOp(CODE_NULL);
							#end
							SExpression({expr: EReturn(), pos: p}, p);
						}
				}
			case [expression = parseExpression()]: {
					#if WREN_COMPILE
					this.vm.compiler.emitOp(CODE_POP);
					#end
					SExpression(expression, expression.pos);
				}
		}
	}

	function parseImport():Statement {
		return switch stream {
			case [{tok: Kwd(KwdImport), pos: p}]: {
					var pos = p;
					var importName:String = switch stream {
						case [{tok: Const(CString(name)), pos: p}]:
							pos = {min: pos.min, max: p.max, file: p.file};
							name;
						case _:
							errors.push(SError('Error at ${peek(0)}: Expect a string after \'import\' \u2190', p, WrenLexer.lineCount));
							null;
					}

					#if WREN_COMPILE
					var moduleConstant = this.vm.compiler.addConstant(ObjString.newString(this.vm, importName));
					// Load the module
					this.vm.compiler.emitShortArg(CODE_IMPORT_MODULE, moduleConstant);
					// Discard the unused result value from calling the module body's closure.
					this.vm.compiler.emitOp(CODE_POP);
					#end

					var variables = [];

					while (true) {
						switch stream {
							case [{tok: Kwd(KwdFor), pos: p}]:
								{
									var isFin = false;
									#if WREN_COMPILE
									// Compile the comma-separated list of variables to import.
									inline function compileVariables(name:String) {
										var slot = this.vm.compiler.declareVariable(name);
										// Define a string constant for the variable name.
										var variableConstant = this.vm.compiler.addConstant(ObjString.newString(this.vm, name));
										// Load the variable from the other module.
										this.vm.compiler.emitShortArg(CODE_IMPORT_VARIABLE, variableConstant);
										// Store the result in the variable here.
										this.vm.compiler.defineVariable(slot);
									}
									#end
									while (true) {
										switch stream {
											case [{tok: Const(CIdent(name)), pos: p}]: {
													#if WREN_COMPILE
													compileVariables(name);
													#end
													variables.push(name);
												}
											case [{tok: Comma, pos: p}]: {
													switch stream {
														case [{tok: Const(CIdent(name)), pos: p}]: {
																#if WREN_COMPILE
																compileVariables(name);
																#end
																variables.push(name);
															}
														case _:
															errors.push(SError('Error at ${peek(0)}: Expect a constant after \'import "$importName" for ${variables.join(",")}\' \u2190',
																p, WrenLexer.lineCount
																- 1));
															isFin = true;
													}
												}
											case [{tok: Line, pos: p}]:
												pos = {min: pos.min, max: p.max, file: p.file};
												isFin = true;
											case [{tok: Eof, pos: p}]:
												pos = {min: pos.min, max: p.max, file: p.file};
												isFin = true;
											case _:
												errors.push(SError('Error at ${peek(0)}: Expect a constant after \'import "$importName" for\'', p,
													WrenLexer.lineCount));
												isFin = true;
										}
										if (isFin)
											break;
									}
								}
							case [{tok: Line, pos: p}]:
								break;
							case [{tok: Eof, pos: p}]:
								break;
							case _:
								break;
						}
					}
					if (variables.length > 0) {
						return SImport(importName, IWithVars(variables), pos);
					} else {
						return SImport(importName, INormal, pos);
					}
				}
		}
	}

	var classVariable:Variable = null;
	var classNameString:Value = null;
	var className:ObjString = null;

	function parseClass(isForeign:Bool = false):Statement {
		final def:Definition<ClassFlag, Array<ClassField>> = {
			name: "",
			doc: "",
			params: [],
			flags: [],
			data: []
		};

		if (isForeign) {
			def.flags.push(HForeign);
		}

		return switch stream {
			case [{tok: Kwd(KwdClass), pos: p}, {tok: Const(CIdent(s))}]: {
					#if WREN_COMPILE
					// Create a variable to store the class in.
					classVariable = new Variable(this.vm.compiler.declareNamedVariable(), this.vm.compiler.scopeDepth == -1 ? SCOPE_MODULE : SCOPE_LOCAL);
					// Create shared class name value
					classNameString = ObjString.newString(this.vm, s);
					// Create class name string to track method duplicates
					className = classNameString.AS_STRING();
					// Make a string constant for the name.
					this.vm.compiler.emitConstant(classNameString);
					#end
					def.name = s;
					var ext = switch stream {
						case [{tok: Kwd(KwdIs)}, {tok: Const(CIdent(ex))}]: {
								ex;
							}
						case _: #if WREN_COMPILE this.vm.compiler.loadCoreVariable("Object"); #end null;
					}

					#if WREN_COMPILE
					// Store a placeholder for the number of fields argument. We don't know the
					// count until we've compiled all the methods to see which fields are used.
					var numFieldsInstruction = -1;
					if (isForeign) {
						this.vm.compiler.emitOp(CODE_FOREIGN_CLASS);
					} else {
						numFieldsInstruction = this.vm.compiler.emitByteArg(CODE_CLASS, 255);
					}
					// Store it in its name.
					this.vm.compiler.defineVariable(classVariable.index);
					// Push a local variable scope. Static fields in a class body are hoisted out
					// into local variables declared in this scope. Methods that use them will
					// have upvalues referencing them.
					this.vm.compiler.pushScope();
					var classInfo:ClassInfo = {
						isForeign: isForeign,
						name: className
					};
					// Set up a symbol table for the class's fields. We'll initially compile
					// them to slots starting at zero. When the method is bound to the class, the
					// bytecode will be adjusted by [wrenBindMethod] to take inherited fields
					// into account.
					classInfo.fields = new SymbolTable(this.vm);

					// Set up symbol buffers to track duplicate static and instance methods.
					classInfo.methods = new IntBuffer(this.vm);
					classInfo.staticMethods = new IntBuffer(this.vm);
					this.vm.compiler.enclosingClass = classInfo;
					#end

					return switch stream {
						case [{tok: BrOpen, pos: p1}]: {
								if (ext != null) {
									def.flags.push(HExtends(ext));
								}
								return switch stream {
									case [fields = parseClassFields()]: {
											def.data = def.data.concat(fields);
											#if WREN_COMPILE
											if (!isForeign) {
												this.vm.compiler.fn.code.data.set(numFieldsInstruction, fields.length);
											}
											// Clear symbol tables for tracking field and method names.
											classInfo.fields.clear();
											classInfo.methods.clear();
											classInfo.staticMethods.clear();
											vm.compiler.enclosingClass = null;
											vm.compiler.popScope();
											#end
											return switch stream {
												case [{tok: BrClose, pos: p1}, {tok: Line}]: return SClass(def, {min: p.min, max: p1.max, file: p.file});
												case _:
													errors.push(SError('unclosed block at class ${def.name} ${ext != null ? 'is $ext' : ''} { \u2190', p1,
														WrenLexer.lineCount));
													null;
											}
										}
								}
							}
					}
				}
		}
	}

	function parseClassFields()
		return parseRepeat(parseClassField);

	function parseClassField():ClassField {
		return switch stream {
			case [{tok: Kwd(KwdConstruct)}, construct = parseConstructor()]: construct; // constructor
			case [{tok: Kwd(KwdStatic)}, {tok: Const(CIdent(s))}, f = parseStaticFields(s)]: f; // static field
			case [{tok: Kwd(KwdForeign)},]: // static foreign field

				{
					switch stream {
						case [{tok: Kwd(KwdStatic)}, {tok: Const(CIdent(s))}, f = parseForeignFields(s, true)]: {
								f;
							}
						case [{tok: Const(CIdent(s))}, f = parseForeignFields(s, false)]: {
								f;
							}
					}
				}
			case [opOverloading = parseOpOverloading()]: opOverloading; // op overloading
			case [{tok: Line}]: parseClassField();
			case [{tok: Comment(s)}]: parseClassField();
			case [{tok: CommentLine(s)}]: parseClassField();
			case [{tok: Const(CIdent(s))}]: {
					#if WREN_COMPILE
					// Build the method signature
					var signature = this.vm.compiler.signatureFromToken(s, SIG_GETTER);
					this.vm.compiler.enclosingClass.signature = signature;
					#end
					return switch stream {
						case [getterSetter = parseSetterGetter(s)]: getterSetter; // getterSetter;
						case [method = parseMethod(s, [])]: method;
						case _: parseClassField();
					}
				}
			case _: throw new hxparse.NoMatch<Dynamic>(curPos(), peek(0));
		}
	}

	function parseStaticFields(name:String):ClassField {
		#if WREN_COMPILE
		this.vm.compiler.enclosingClass.inStatic = true;
		// Build the method signature
		var signature = this.vm.compiler.signatureFromToken(name, SIG_GETTER);
		this.vm.compiler.enclosingClass.signature = signature;
		#end
		return switch stream {
			case [getterSetter = parseSetterGetter(name, true)]: getterSetter; // getterSetter;
			case [method = parseMethod(name, [AStatic])]: method;
			case _: throw new hxparse.NoMatch<Dynamic>(curPos(), peek(0));
		}
	}

	function parseForeignFields(name:String, isStatic:Bool = false):ClassField {
		var access = isStatic ? [AForeign, AStatic] : [AForeign];
		#if WREN_COMPILE
		this.vm.compiler.enclosingClass.inStatic = isStatic;
		// Build the method signature
		var signature = this.vm.compiler.signatureFromToken(name, SIG_GETTER);
		this.vm.compiler.enclosingClass.signature = signature;
		#end
		return switch stream {
			case [getterSetter = parseSetterGetter(name, true, true)]: getterSetter; // getterSetter;
			case [method = parseMethod(name, access)]: method;
			case _: throw new hxparse.NoMatch<Dynamic>(curPos(), peek(0));
		}
	}

	function parseMethod(name:String, access:Array<Access>) {
		var params = [];
		var isForeign = false;
		var pos = null;

		switch stream {
			case [{tok: POpen}, _params = parseRepeat(parseParamNames)]:
				{
					// trace(name, access, peek(0), _params);
					while (true) {
						switch stream {
							case [{tok: PClose, pos: p2}]:
								params = _params;
								pos = p2;
							case [{tok: Line}]: // ignore
							case _: break;
						}
					}
				}
				// case [{tok: Line}]: // ignore
		}
		var isStatic = false;
		var isForeign = false;
		switch access {
			case [AForeign, AStatic]:
				isStatic = true;
				isForeign = true;
			case [AForeign]:
				isForeign = true;
			case [AStatic]:
				isStatic = true;
				isForeign = false;
			case _:
				isForeign = false;
		}

		#if WREN_COMPILE
		var isConstructor = switch access {
			case [AConstructor]: true;
			case _: false;
		};
		var signature = this.vm.compiler.enclosingClass.signature;

		this.vm.compiler.enclosingClass.signature.type = isConstructor ? SIG_INITIALIZER : SIG_METHOD;
		this.vm.compiler.enclosingClass.signature.arity = 1;

		var methodCompiler = Compiler.init(this, this.vm.compiler, true);

		for (arg in params) {
			methodCompiler.validateNumParameters(++this.vm.compiler.enclosingClass.signature.arity);
			methodCompiler.declareVariable((new Token(Const(arg), pos)).toString());
		}
		this.vm.compiler.enclosingClass.signature.arity++;

		// Include the full signature in debug messages in stack traces.
		var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
		// Check for duplicate methods. Doesn't matter that it's already been
		// defined, error will discard bytecode anyway.
		// Check if the method table already contains this symbol
		var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);

		if (isForeign) {
			// Define a constant for the signature.
			this.vm.compiler.emitConstant(ObjString.newString(this.vm, fullSignature));
			// We don't need the function we started compiling in the parameter list
			// any more.
			methodCompiler.parser.vm.compiler = methodCompiler.parent;
			this.vm.compiler.defineMethod(classVariable, isStatic, methodSymbol);

			if (isConstructor) {
				// Also define a matching constructor method on the metaclass.
				this.vm.compiler.enclosingClass.signature.type = SIG_METHOD;
				var constructorSymbol = this.vm.compiler.signatureSymbol(signature);

				// this.vm.compiler.createConstructor(signature, methodSymbol);

				// Allocate the instance.
				methodCompiler.emitOp(CODE_FOREIGN_CONSTRUCT);
				// Run its initializer.
				methodCompiler.emitShortArg(cast(CODE_CALL_0 + signature.arity, Code), constructorSymbol);

				methodCompiler.endCompiler("");

				this.vm.compiler.defineMethod(classVariable, true, constructorSymbol);
			}
		}
		#end

		if (!isForeign) {
			return switch stream {
				case [{tok: BrOpen, pos: p2}]: {
						var hasReturn = peek(0).tok != Line;

						var body = parseRepeat(parseStatements);
						#if WREN_COMPILE
						compileBody(methodCompiler, isConstructor, hasReturn);
						methodCompiler.endCompiler(fullSignature);
						this.vm.compiler.defineMethod(classVariable, isStatic, methodSymbol);
						if (isConstructor) {
							// Also define a matching constructor method on the metaclass.
							this.vm.compiler.enclosingClass.signature.type = SIG_METHOD;
							var constructorSymbol = this.vm.compiler.signatureSymbol(signature);

							// this.vm.compiler.createConstructor(signature, methodSymbol);
							// Allocate the instance.
							methodCompiler.emitOp(CODE_CONSTRUCT);
							// Run its initializer.
							methodCompiler.emitShortArg(cast(CODE_CALL_0 + signature.arity, Code), constructorSymbol);

							methodCompiler.endCompiler("");
							this.vm.compiler.defineMethod(classVariable, true, constructorSymbol);
						}
						#end
						switch stream {
							case [{tok: BrClose}, {tok: Line}]: {
									return {
										name: name,
										doc: null,
										access: access,
										kind: FMethod(params, body),
										pos: p2
									};
								}
							case [{tok: Eof}]:
								errors.push(SError('unclosed block at ${[for (a in access) AccessPrinter.toString(a)].join(" ")} ${name}() \u2190', p2,
									WrenLexer.lineCount));
								null;
							case _: {
									errors.push(SError('unclosed block at ${[for (a in access) AccessPrinter.toString(a)].join(" ")} ${name}() \u2190', p2,
										WrenLexer.lineCount));
									null;
								}
						}
					}
				case _:
					trace(this.last);
					errors.push(SError('Error at \'${peek(0)}\' : Expect \'{\' to begin a method body', null, WrenLexer.lineCount));
					null;
			}
		}
		return {
			name: name,
			doc: null,
			access: access,
			kind: FMethod(params, []),
			pos: pos
		};
	}

	function parseConstructor() {
		return switch stream {
			case [{tok: Const(CIdent(c))}]: {
					return parseMethod(c, [AConstructor]);
				}
		}
	}

	function parseOpOverloading() {
		return switch stream {
			// op { body }
			case [{tok: Unop(op)}, {tok: BrOpen, pos: p}]: {
					#if WREN_COMPILE
					// Add the RHS parameter.
					this.vm.compiler.enclosingClass.signature.type = SIG_GETTER;
					var methodCompiler = Compiler.init(this, this.vm.compiler, true);

					// Include the full signature in debug messages in stack traces.
					var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
					// Check for duplicate methods. Doesn't matter that it's already been
					// defined, error will discard bytecode anyway.
					// Check if the method table already contains this symbol
					var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);
					#end
					var code = parseRepeat(parseStatements);

					#if WREN_COMPILE
					compileBody(methodCompiler, false, true);
					methodCompiler.endCompiler(fullSignature);
					this.vm.compiler.defineMethod(classVariable, false, methodSymbol);
					#end
					switch stream {
						case [{tok: BrClose}]:
							{
								return {
									name: TokenDefPrinter.toString(Unop(op)),
									doc: null,
									access: [],
									kind: FOperator(FPrefixOp(op, code)),
									pos: p
								};
							}
						case _:
							errors.push(SError('Error at ${peek(0)}: unclosed block at operator ${TokenDefPrinter.toString(Unop(op))} \u2190', p,
								WrenLexer.lineCount));
							null;
					}
				}
			case [{tok: Binop(op)}]: {
					return switch stream {
						// op(other) { body }
						case [{tok: POpen}, {tok: Const(CIdent(other))}, {tok: PClose}, {tok: BrOpen, pos: p}]: {
								#if WREN_COMPILE
								// Add the RHS parameter.
								this.vm.compiler.enclosingClass.signature.type = SIG_METHOD;
								this.vm.compiler.enclosingClass.signature.arity = 1;
								var methodCompiler = Compiler.init(this, this.vm.compiler, true);
								methodCompiler.declareVariable(new Token(Const(CIdent(other)), p).toString());
								// Include the full signature in debug messages in stack traces.
								var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
								// Check for duplicate methods. Doesn't matter that it's already been
								// defined, error will discard bytecode anyway.
								// Check if the method table already contains this symbol
								var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);
								#end
								var code = parseRepeat(parseStatements);

								#if WREN_COMPILE
								compileBody(methodCompiler, false, true);
								methodCompiler.endCompiler(fullSignature);
								this.vm.compiler.defineMethod(classVariable, false, methodSymbol);
								#end
								return switch stream {
									case [{tok: BrClose}]:
										{
											return {
												name: TokenDefPrinter.toString(Binop(op)),
												doc: null,
												access: [],
												kind: FOperator(FInfixOp(op, CIdent(other), code)),
												pos: p
											};
										}
									case _:
										errors.push(SError('Error at ${peek(0)}: unclosed block at operator ${TokenDefPrinter.toString(Binop(op))} \u2190', p,
											WrenLexer.lineCount));
										null;
								}
							}
						// - {}
						case [{tok: BrOpen, pos: p}]: {
								#if WREN_COMPILE
								// Add the RHS parameter.
								this.vm.compiler.enclosingClass.signature.type = SIG_GETTER;
								var methodCompiler = Compiler.init(this, this.vm.compiler, true);
								// methodCompiler.declareVariable(new Token(Const(CIdent(other)), p).toString());
								// Include the full signature in debug messages in stack traces.
								var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
								// Check for duplicate methods. Doesn't matter that it's already been
								// defined, error will discard bytecode anyway.
								// Check if the method table already contains this symbol
								var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);
								#end
								var code = parseRepeat(parseStatements);
								#if WREN_COMPILE
								compileBody(methodCompiler, false, true);
								methodCompiler.endCompiler(fullSignature);

								this.vm.compiler.defineMethod(classVariable, false, methodSymbol);
								#end
								if (op == OpSub) {
									return switch stream {
										case [{tok: BrClose}]:
											return {
												name: TokenDefPrinter.toString(Binop(op)),
												doc: null,
												access: [],
												kind: FOperator(FPrefixOp(OpNeg, code)),
												pos: p
											};

										case _:
											errors.push(SError('Error at ${peek(0)}: unclosed block at operator ${TokenDefPrinter.toString(Binop(op))} \u2190',
												p,
												WrenLexer.lineCount
												- 1));
											null;
									}
								} else {
									throw unexpected();
								}
							}
					}
				}
			// [_] or [_]=value
			case [{tok: BkOpen, pos: p}]: {
					var subscript_params = [];

					while (true) {
						switch stream {
							case [{tok: Const(CIdent(s))}]: subscript_params.push(CIdent(s));
							case [{tok: Comma}]: continue;
							case [{tok: BkClose}]: break;
						}
					}
					var rhs = switch stream {
						case [getterSetter = parseSetterGetter("", false, false, true)]: {
								getterSetter; // getterSetter;
							}
						case _: unexpected();
					}

					return {
						name: "$ArrayGetSet",
						doc: null,
						access: [],
						kind: FOperator(FSubscriptOp(subscript_params, rhs.kind)),
						pos: p
					}
				}
			// is(other) { body }
			case [
				{tok: Kwd(KwdIs)},
				{tok: POpen},
				{tok: Const(CIdent(other))},
				{tok: PClose},
				{tok: BrOpen, pos: p}
			]: {
					#if WREN_COMPILE
					// Add the RHS parameter.
					this.vm.compiler.enclosingClass.signature.type = SIG_METHOD;
					this.vm.compiler.enclosingClass.signature.arity = 1;
					var methodCompiler = Compiler.init(this, this.vm.compiler, true);
					methodCompiler.declareVariable(new Token(Const(CIdent(other)), p).toString());
					// Include the full signature in debug messages in stack traces.
					var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
					// Check for duplicate methods. Doesn't matter that it's already been
					// defined, error will discard bytecode anyway.
					// Check if the method table already contains this symbol
					var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);
					#end
					var code = parseRepeat(parseStatements);

					#if WREN_COMPILE
					compileBody(methodCompiler, false, true);
					methodCompiler.endCompiler(fullSignature);

					this.vm.compiler.defineMethod(classVariable, false, methodSymbol);
					#end
					var name = "$is";
					return switch stream {
						case [{tok: BrClose}]: {
								name: name,
								doc: null,
								access: [],
								kind: FOperator(FInfixOp(OpIs, CIdent(other), code)),
								pos: p
							}
						case _:
							errors.push(SError('Error at \'${peek(0)}\': Expect \'}\'', p, WrenLexer.lineCount));
							return null;
					}
				}
			// %(
			case [
				{tok: Interpol},
				{tok: Const(CIdent(other))},
				{tok: PClose},
				{tok: BrOpen, pos: p}
			]: {
					#if WREN_COMPILE
					// Add the RHS parameter.
					this.vm.compiler.enclosingClass.signature.type = SIG_METHOD;
					this.vm.compiler.enclosingClass.signature.arity = 1;
					var methodCompiler = Compiler.init(this, this.vm.compiler, true);
					methodCompiler.declareVariable(new Token(Const(CIdent(other)), p).toString());
					// Include the full signature in debug messages in stack traces.
					var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
					// Check for duplicate methods. Doesn't matter that it's already been
					// defined, error will discard bytecode anyway.
					// Check if the method table already contains this symbol
					var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);
					#end
					var code = parseRepeat(parseStatements);
					#if WREN_COMPILE
					compileBody(methodCompiler, false, true);
					methodCompiler.endCompiler(fullSignature);
					this.vm.compiler.defineMethod(classVariable, false, methodSymbol);
					#end
					var name = "$mod";
					return switch stream {
						case [{tok: BrClose}]: {
								name: name,
								doc: null,
								access: [],
								kind: FOperator(FInfixOp(OpMod, CIdent(other), code)),
								pos: p
							}
						case _:
							errors.push(SError('Error at \'${peek(0)}\': Expect \'}\'', p, WrenLexer.lineCount));
							return null;
					}
				}
		}
	}

	function parseSetterGetter(s:String, _static:Bool = false, _foreign:Bool = false, _subscript = false) {
		var access = [];
		if (_foreign)
			access.push(AForeign);
		if (_static)
			access.push(AStatic);

		#if WREN_COMPILE
		// Build the method signature
		var signature = this.vm.compiler.signatureFromToken(s, _subscript ? SIG_SUBSCRIPT : SIG_GETTER);
		this.vm.compiler.enclosingClass.signature = signature;
		this.vm.compiler.enclosingClass.signature.type = _subscript ? SIG_SUBSCRIPT : SIG_GETTER;
		#end

		return switch stream {
			// setter
			case [{tok: Binop(OpAssign), pos: p2}]: {
					return switch stream {
						case [{tok: POpen}, {tok: Const(CIdent(c))}]: {
								switch stream {
									case [{tok: PClose, pos: p2}]: {
											var body = makeSetter(s, CIdent(c), p2, access, _subscript);
											return body;
										}
									case _: {
											errors.push(SError('Error at ${peek(0)}: Expect \')\' at setter', p2, WrenLexer.lineCount));
											return null;
										}
								}
							}
						case [{tok: PClose, pos: p2}]: {
								errors.push(SError('Error at ${peek(0)}: Expect variable name', p2, WrenLexer.lineCount));
								return null;
							}
						case _: {
								errors.push(SError('Error at ${peek(0)}: Expect variable name', p2, WrenLexer.lineCount));
								return null;
							}
					}
				}
			// method (no-args) && Getter
			case [{tok: BrOpen, pos: p0}]: {
					#if WREN_COMPILE
					var methodCompiler = Compiler.init(this, this.vm.compiler, true);
					var methodSymbol = -1;
					var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
					if (peek(0).tok != Line) {
						// Check for duplicate methods. Doesn't matter that it's already been
						// defined, error will discard bytecode anyway.
						// Check if the method table already contains this symbol
						methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);
					}
					#end
					if (_foreign) {
						errors.push(SError('Error at \'{\': foreign field \'$s\' cannot have body', p0, WrenLexer.lineCount));
						null;
					} else {
						var data = null;
						switch stream {
							// method (no-args)
							case [{tok: Line, pos: p}]: {
									data = makeMethod(s, [], p, access, false);
									data;
								}
							// Getter
							case [exp = parseExpression(), {tok: BrClose, pos: p}]: {
									#if WREN_COMPILE
									compileBody(methodCompiler, false, true);
									methodCompiler.endCompiler(fullSignature);
									this.vm.compiler.defineMethod(classVariable, _static, methodSymbol);
									#end
									data = {
										name: s,
										doc: null,
										access: access,
										kind: FGetter(SExpression(exp, exp.pos)),
										pos: exp.pos
									}

									data;
								}
							case [{tok: BrClose, pos: p}]: {
									#if WREN_COMPILE
									compileBody(methodCompiler, false, true);
									methodCompiler.endCompiler(fullSignature);
									this.vm.compiler.defineMethod(classVariable, _static, methodSymbol);
									#end
									data = {
										name: s,
										doc: null,
										access: access,
										kind: FGetter(SExpression(null, p)),
										pos: p
									}

									data;
								}
						}
					}
				}
			case [{tok: Line, pos: p0}]: {
					#if WREN_COMPILE
					var methodCompiler = Compiler.init(this, this.vm.compiler, true);
					// Include the full signature in debug messages in stack traces.
					var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
					// Check for duplicate methods. Doesn't matter that it's already been
					// defined, error will discard bytecode anyway.
					// Check if the method table already contains this symbol
					var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);

					if (_foreign) {
						// Define a constant for the signature.
						this.vm.compiler.emitConstant(ObjString.newString(this.vm, fullSignature));
						// We don't need the function we started compiling in the parameter list
						// any more.
						methodCompiler.parser.vm.compiler = methodCompiler.parent;
					} else {
						compileBody(methodCompiler, false, false);
						methodCompiler.endCompiler(fullSignature);
					}
					this.vm.compiler.defineMethod(classVariable, _static, methodSymbol);
					#end
					if (_foreign) {
						var data = {
							name: s,
							doc: null,
							access: access,
							kind: FGetter(null),
							pos: p0
						}
						return data;
					} else {
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at getter $s', p0, WrenLexer.lineCount));
						null;
					}
				}
			case [{tok: Eof, pos: p0}]: {
					#if WREN_COMPILE
					var methodCompiler = Compiler.init(this, this.vm.compiler, true);
					// Include the full signature in debug messages in stack traces.
					var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
					// Check for duplicate methods. Doesn't matter that it's already been
					// defined, error will discard bytecode anyway.
					// Check if the method table already contains this symbol
					var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);

					if (_foreign) {
						// Define a constant for the signature.
						this.vm.compiler.emitConstant(ObjString.newString(this.vm, fullSignature));
						// We don't need the function we started compiling in the parameter list
						// any more.
						methodCompiler.parser.vm.compiler = methodCompiler.parent;
					} else {
						compileBody(methodCompiler, false, false);
						methodCompiler.endCompiler(fullSignature);
					}
					this.vm.compiler.defineMethod(classVariable, _static, methodSymbol);
					#end
					if (_foreign) {
						var data = {
							name: s,
							doc: null,
							access: access,
							kind: FGetter(null),
							pos: p0
						}

						data;
					} else {
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at getter $s', p0, WrenLexer.lineCount));
						null;
					}
				}
		}
	}

	function makeMethod(name, args:Array<Constant>, pos, access:Array<Access>, hasReturn:Bool = false) {
		var code = [];
		#if WREN_COMPILE
		var isStatic = false;
		var isForeign = switch access {
			case [AForeign, AStatic]:
				isStatic = true;
				true;
			case [AForeign]: true;
			case [AStatic]:
				isStatic = true;
				false;
			case _: false;
		};

		var signature = this.vm.compiler.enclosingClass.signature;

		this.vm.compiler.enclosingClass.signature.type = SIG_METHOD;
		this.vm.compiler.enclosingClass.signature.arity = 1;

		var methodCompiler = Compiler.init(this, this.vm.compiler, true);
		for (arg in args) {
			methodCompiler.validateNumParameters(++this.vm.compiler.enclosingClass.signature.arity);
			methodCompiler.declareVariable((new Token(Const(arg), pos)).toString());
		}
		this.vm.compiler.enclosingClass.signature.arity++;

		// Include the full signature in debug messages in stack traces.
		var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
		// Check for duplicate methods. Doesn't matter that it's already been
		// defined, error will discard bytecode anyway.
		// Check if the method table already contains this symbol
		var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);

		if (isForeign) {
			// Define a constant for the signature.
			this.vm.compiler.emitConstant(ObjString.newString(this.vm, fullSignature));
			// We don't need the function we started compiling in the parameter list
			// any more.
			methodCompiler.parser.vm.compiler = methodCompiler.parent;
		} else {
		#end
			code = parseRepeat(parseStatements);
		#if WREN_COMPILE
		compileBody(methodCompiler, false, false);
		methodCompiler.endCompiler(fullSignature);
		} this.vm.compiler.defineMethod(classVariable, isStatic, methodSymbol);
		#end

		switch stream {
			case [{tok: BrClose}]:
				{}
			case [{tok: Eof}]:
				errors.push(SError('Error: Expect \'}\', unclosed block at method ${name} \u2190', pos, WrenLexer.lineCount));
				null;
		}
		return {
			name: name,
			doc: null,
			access: access,
			kind: FMethod(args, code),
			pos: pos
		}
	}

	function makeSetter(name, arg, pos, access:Array<Access>, _subscript = false) {
		var isStatic = false;
		var isForeign = switch access {
			case [AForeign, AStatic]:
				isStatic = true;
				true;
			case [AForeign]: true;
			case [AStatic]:
				isStatic = true;
				false;
			case _: false;
		};

		#if WREN_COMPILE
		this.vm.compiler.enclosingClass.signature.type = _subscript ? SIG_SUBSCRIPT_SETTER : SIG_SETTER;
		var methodCompiler = Compiler.init(this, this.vm.compiler, true);
		methodCompiler.declareVariable(new Token(Const(arg), pos).toString());
		this.vm.compiler.enclosingClass.signature.arity++;

		// Include the full signature in debug messages in stack traces.
		var fullSignature = this.vm.compiler.enclosingClass.signature.toString();
		// Check for duplicate methods. Doesn't matter that it's already been
		// defined, error will discard bytecode anyway.
		// Check if the method table already contains this symbol
		var methodSymbol = this.vm.compiler.declareMethod(this.vm.compiler.enclosingClass.signature, fullSignature);

		if (isForeign) {
			// Define a constant for the signature.
			this.vm.compiler.emitConstant(ObjString.newString(this.vm, fullSignature));
			// We don't need the function we started compiling in the parameter list
			// any more.
			methodCompiler.parser.vm.compiler = methodCompiler.parent;
			this.vm.compiler.defineMethod(classVariable, isStatic, methodSymbol);
		}
		#end

		return switch stream {
			case [{tok: BrOpen, pos: p}]:
				{
					if (isForeign) {
						errors.push(SError('Error at \'{\': foreign field cannot have body ', p, WrenLexer.lineCount));
						return null;
					} else {
						var code = parseRepeat(parseStatements);
						switch stream {
							case [{tok: BrClose}]: {
									#if WREN_COMPILE
									compileBody(methodCompiler, false, false);
									methodCompiler.endCompiler(fullSignature);
									#end
								}
							case [{tok: Eof}]:
								errors.push(SError('unclosed block at setter ${name} \u2190', p, WrenLexer.lineCount));
								return null;
							case _: {
									errors.push(SError('unclosed block at setter ${name} \u2190', p, WrenLexer.lineCount));
									return null;
								}
						}
						#if WREN_COMPILE
						this.vm.compiler.defineMethod(classVariable, isStatic, methodSymbol);
						#end
						return {
							name: name,
							doc: null,
							access: access,
							kind: FSetter(arg, code),
							pos: pos
						};
					}
				}
			case [{tok: Line, pos: p0}]:
				{
					if (isForeign) {
						return {
							name: name,
							doc: null,
							access: access,
							kind: FSetter(arg, []),
							pos: pos
						};
					} else {
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at setter $name', p0, WrenLexer.lineCount));
						null;
					}
				}
			case [{tok: Eof, pos: p0}]:
				{
					if (isForeign)
						return {
							name: name,
							doc: null,
							access: access,
							kind: FSetter(arg, []),
							pos: pos
						};
					else {
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at setter $name', p0, WrenLexer.lineCount));
						null;
					}
				}
		}
	}

	function parseParamNames() {
		return switch stream {
			case [{tok: Const(CIdent(s)), pos: p}]: {
					switch stream {
						case [{tok: Line}]: {} // ignore
						case _:
					}
					CIdent(s);
				}
			case [{tok: Kwd(k), pos: p}]:
				errors.push(SError('invalid argument ${KeywordPrinter.toString(k)} at $p', p, WrenLexer.lineCount));
				null;
			case [{tok: Comma}]: {
					switch stream {
						case [{tok: Line}]: {} // ignore
						case _:
					}
					parseParamNames();
				}
		}
	}

	#if WREN_COMPILE
	/**
	 * Compiles the body of a method
	 * @param methodCompiler
	 * @param isReturn
	 * @param isInitializer
	 */
	inline function compileBody(methodCompiler:Compiler, isInitializer:Bool = false, isReturn:Bool = false) {
		if (isInitializer) {
			if (isReturn) {
				methodCompiler.emitOp(CODE_POP);
			}
			// The receiver is always stored in the first local slot
			methodCompiler.emitOp(CODE_LOAD_LOCAL_0);
		} else if (!isReturn) {
			methodCompiler.emitOp(CODE_NULL);
		}
		methodCompiler.emitOp(CODE_RETURN);
	}
	#end

	function parseControlFlow() {
		#if WREN_COMPILE
		switch peek(0).tok {
			case Kwd(KwdFor):
				{
					this.vm.compiler.pushScope();
				}
			case Kwd(KwdWhile):
				{
					var loop:Loop = {};
					this.vm.compiler.startLoop(loop);
				}
			case _:
		}
		#end
		return switch stream {
			case [{tok: Kwd(KwdIf)}, {tok: POpen}, exp = parseExpression(), {tok: PClose}]: {
					#if WREN_COMPILE
					// Jump to the else branch if the condition is false.
					var ifJump = this.vm.compiler.emitJump(CODE_JUMP_IF);
					#end
					// Compile the then branch.
					switch stream {
						case [{tok: BrOpen, pos: p}, body = parseRepeat(parseStatements)]:
							{
								while (true) {
									switch stream {
										case [{tok: BrClose}]: break;
										case [{tok: Line}]: continue;
										case [{tok: Comment(s)}]: continue;
										case [{tok: CommentLine(s)}]: continue;
										case _:
											errors.push(SError('Expect \'}\' at ${peek(0)}', p, WrenLexer.lineCount));
											break;
									}
								}
								// Compile the else branch if there is one.
								switch stream {
									case [{tok: Kwd(KwdElse), pos: p}]: {
											var elseBody = [];
											#if WREN_COMPILE
											var elseJump = this.vm.compiler.emitJump(CODE_JUMP);
											this.vm.compiler.patchJump(ifJump);
											#end
											switch stream {
												case [{tok: BrOpen}]: {
														elseBody.concat(parseRepeat(parseStatements));
														while (true) {
															switch stream {
																case [{tok: BrClose}]: break;
																case [{tok: Comment(s)}]: continue;
																case [{tok: CommentLine(s)}]: continue;
																case [{tok: Line}]: continue;
																case _:
																	errors.push(SError('Expect \'}\' at ${peek(0)}', p, WrenLexer.lineCount));
																	break;
															}
														}
													}
												case [exp = parseRepeat(parseStatements)]: elseBody.concat(parseRepeat(parseStatements));
											}
											#if WREN_COMPILE
											// Patch the jump over the else.
											this.vm.compiler.patchJump(elseJump);
											#end
											return SIf(exp, body, elseBody);
										}
									case _:
								}
								#if WREN_COMPILE
								this.vm.compiler.patchJump(ifJump);
								#end
								return SIf(exp, body, []);
							}
						case [body = parseExpression()]:
							{
								var elseBody = [];
								while (true) {
									switch stream {
										case [{tok: Kwd(KwdElse), pos: p}]: {
												#if WREN_COMPILE
												var elseJump = this.vm.compiler.emitJump(CODE_JUMP);
												this.vm.compiler.patchJump(ifJump);
												#end
												switch stream {
													case [{tok: Kwd(KwdIf)}]: elseBody.push(parseControlFlow());
													case [{tok: BrOpen}]: elseBody.push(parseStatements());
													case _: elseBody.push(SExpression(parseExpression(), p));
												}
												#if WREN_COMPILE
												if (elseBody.length > 0) {
													// Patch the jump over the else.
													this.vm.compiler.patchJump(elseJump);
												}
												#end
											}
										case [{tok: Comment(s)}]: continue;
										case [{tok: CommentLine(s)}]: continue;
										case [{tok: Line}]: break;
									}
								}
								#if WREN_COMPILE
								if (elseBody.length > 0) {} else {
									this.vm.compiler.patchJump(ifJump);
								}
								#end
								return SIf(exp, [SExpression(body, body.pos)], elseBody);
							}

							// case _ : unexpected();
					}
				}
			case [
				{tok: Kwd(KwdFor)},
				{tok: POpen},
				{tok: Const(CIdent(s))},
				{tok: Binop(OpIn)},
				exp = parseExpression(),
				{tok: PClose},
				{tok: BrOpen, pos: p}
			]: {
					#if WREN_COMPILE
					var loopVarName = s;

					// Verify that there is space to hidden local variables.
					// Note that we expect only two addLocal calls next to each other in the
					// following code.
					if (this.vm.compiler.numLocals + 2 > Compiler.MAX_LOCALS) {
						this.vm.compiler.error('Cannot declare more than ${Compiler.MAX_LOCALS} variables in one scope. (Not enough space for for-loops internal variables)');
						return null;
					}
					var seqSlot = this.vm.compiler.addLocal("seq ");
					// Create another hidden local for the iterator object.
					this.vm.compiler.emitOp(CODE_NULL);
					var iterSlot = this.vm.compiler.addLocal("iter ");
					var loop:Loop = {};
					this.vm.compiler.startLoop(loop);
					// Advance the iterator by calling the ".iterate" method on the sequence.
					this.vm.compiler.loadLocal(seqSlot);
					this.vm.compiler.loadLocal(iterSlot);

					// Update and test the iterator.
					callMethod(1, "iterate(_)");
					this.vm.compiler.emitByteArg(CODE_STORE_LOCAL, iterSlot);
					this.vm.compiler.testExitLoop();
					this.vm.compiler.loadLocal(seqSlot);
					this.vm.compiler.loadLocal(iterSlot);
					callMethod(1, "iteratorValue(_)");
					// Bind the loop variable in its own scope. This ensures we get a fresh
					// variable each iteration so that closures for it don't all see the same one.
					this.vm.compiler.pushScope();
					this.vm.compiler.addLocal(loopVarName);
					this.vm.compiler.loopBody();
					#end
					var body = parseRepeat(parseStatements);
					#if WREN_COMPILE
					// Loop variable.
					this.vm.compiler.popScope();
					this.vm.compiler.endLoop();
					// Hidden variables.
					this.vm.compiler.popScope();
					#end
					while (true) {
						switch stream {
							case [{tok: BrClose}]: break;
							case [{tok: Line}]: continue;
							case _:
								errors.push(SError('Expect \'}\' at ${peek(0)}', p, WrenLexer.lineCount));
								break;
						}
					}
					return SFor({expr: EFor(exp, {expr: EConst(CIdent(s)), pos: p}), pos: p}, body);
				}
			case [
				{tok: Kwd(KwdWhile)},
				{tok: POpen},
				// Compile the condition.
				exp = parseExpression(),
				{tok: PClose},
				{tok: BrOpen, pos: p}
			]: {
					#if WREN_COMPILE
					// inside a body
					this.vm.compiler.pushScope();

					this.vm.compiler.testExitLoop();
					this.vm.compiler.loopBody();
					#end
					var body = [];
					while (true) {
						switch stream {
							case [b = parseStatements()]:
								body.push(cast b);
								continue;
							case [{tok: BrClose}]: break;
							case [{tok: Line}]: continue;
							case _:
								errors.push(SError('Expect \'}\' at ${peek(0)}', p, WrenLexer.lineCount));
								break;
						}
					}
					#if WREN_COMPILE
					this.vm.compiler.endLoop();
					#end
					return SWhile({expr: EWhile(exp, null, true), pos: p}, body);
				}
		}
	}

	function parseExpression() {
		return switch stream {
			case [{tok: Kwd(KwdBreak), pos: p}]: {
					#if WREN_COMPILE
					if (this.vm.compiler.loop == null) {
						this.vm.compiler.error("Cannot use 'break' outside of a loop.");
						return null;
					}
					// Since we will be jumping out of the scope, make sure any locals in it
					// are discarded first.
					this.vm.compiler.discardLocals(this.vm.compiler.loop.scopeDepth + 1);
					// Emit a placeholder instruction for the jump to the end of the body. When
					// we're done compiling the loop body and know where the end is, we'll
					// replace these with `CODE_JUMP` instructions with appropriate offsets.
					// We use `CODE_END` here because that can't occur in the middle of
					// bytecode.
					this.vm.compiler.emitJump(CODE_END);
					#end
					{expr: EBreak, pos: p};
				}
			case [{tok: Kwd(KwdReturn), pos: p}]:
				#if WREN_COMPILE
				this.vm.compiler.emitOp(CODE_RETURN);
				#end
				switch stream {
					case [exp = parseExpression()]: {
							{expr: EReturn(exp), pos: exp.pos};
						}
					case _: {
							#if WREN_COMPILE
							this.vm.compiler.emitOp(CODE_NULL);
							#end
							{expr: EReturn(), pos: p};
						}
				}
			// case [map = parseMap()]: map;
			case [exp = assignment()]: exp;
		}
	}

	function getEnclosingClassCompiler(compiler:Compiler) {
		while (compiler != null) {
			if (compiler.enclosingClass != null)
				return compiler;
			compiler = compiler.parent;
		}
		return null;
	}

	function getEnclosingClass(compiler:Compiler) {
		compiler = getEnclosingClassCompiler(compiler);
		return compiler == null ? null : compiler.enclosingClass;
	}

	function getPrimary() {
		return switch stream {
			case [{tok: Const(c), pos: p}]: {
					switch c {
						case CIdent(s): {
								return {expr: EVars([{name: s, expr: null, type: null}]), pos: p};
							}
						case CInt(i): {
								#if WREN_COMPILE
								this.vm.compiler.emitConstant(Value.NUM_VAL(Std.parseInt(i)));
								#end
								return {expr: EConst(c), pos: p};
							}
						case CFloat(f): {
								#if WREN_COMPILE
								this.vm.compiler.emitConstant(Value.NUM_VAL(Std.parseFloat(f)));
								#end
								return {expr: EConst(c), pos: p};
							}
						case CString(s): {
								#if WREN_COMPILE
								// check interpolation

								if (StringTools.contains(s, "%")) {
									var stringParser = new StringParser(s);
									stringParser.vm = this.vm;
									var splits = stringParser.exec();
									if (stringParser.errors.length > 0) {
										this.errors.concat(stringParser.errors);
										return null;
									}
									// is interpol
									// Instantiate a new list.

									this.vm.compiler.loadCoreVariable("List");
									callMethod(0, "new()");

									for (v in splits) {
										switch v.expr {
											case EConst(CString(_s)): {
													// capture trailing literals
													var stringValue = ObjString.newString(this.vm, _s);
													this.vm.compiler.emitConstant(stringValue);
													callMethod(1, "addCore_(_)");
												}
											case EParenthesis(_): {
													callMethod(1, "addCore_(_)");
												}
											case _:
										}
									}
									// The list of interpolated parts.
									callMethod(0, "join()");
								} else {
									// is string literal
									var stringValue = ObjString.newString(this.vm, s);
									this.vm.compiler.emitConstant(stringValue);
								}
								#end
								return {expr: EConst(c), pos: p};
							}
						case _: throw new NoMatch<Dynamic>(curPos(), null);
					}
				}
			case [{tok: Kwd(KwdNull), pos: p}]: {
					#if WREN_COMPILE
					this.vm.compiler.emitOp(CODE_NULL);
					#end
					return {expr: ENull, pos: p};
				}
			case [{tok: Kwd(KwdThis), pos: p}]: {
					#if WREN_COMPILE
					if (getEnclosingClass(this.vm.compiler) == null) {
						this.vm.compiler.error("Cannot use 'this' outside of a method.");
					}
					this.vm.compiler.loadThis();
					#end
					return {expr: EConst(CIdent("this")), pos: p};
				}
			case [{tok: Kwd(KwdSuper), pos: p}]: {
					#if WREN_COMPILE
					if (getEnclosingClass(this.vm.compiler) == null) {
						this.vm.compiler.error("Cannot use 'super' outside of a method.");
					}
					this.vm.compiler.loadThis();
					#end
					return {expr: EConst(CIdent("super")), pos: p};
				}
			case [{tok: Kwd(KwdTrue), pos: p}]: {
					compileBool(true);
					return {expr: EConst(CIdent("true")), pos: p};
				}

			case [{tok: Kwd(KwdFalse), pos: p}]: {
					compileBool(false);
					return {expr: EConst(CIdent("false")), pos: p};
				}

			case [{tok: POpen, pos: p}, exp = parseExpression()]: {
					switch stream {
						case [{tok: PClose}]: {}
						case _: errors.push(SError('Expect \')\' after expression', p, WrenLexer.lineCount));
					}

					return {expr: EParenthesis(exp), pos: p};
				}

			case [list = parseList()]: list;
			case [map = parseMap()]: map;
		}
	}

	function compileBool(b:Bool) {
		#if WREN_COMPILE
		this.vm.compiler.emitOp(b ? CODE_TRUE : CODE_FALSE);
		#end
	}

	function parseMap() {
		return switch stream {
			case [{tok: BrOpen, pos: p}]: {
					#if WREN_COMPILE
					// Instantiate a new map.
					this.vm.compiler.loadCoreVariable("Map");
					callMethod(0, "new()");
					#end
					var objectFields:Array<ObjectField> = [];
					while (true) {
						switch stream {
							case [{tok: Comma}]: {
									if (objectFields.length == 0)
										unexpected();
									continue;
								}
							case [{tok: Line}]: {
									continue;
								}
							case [{tok: Comment(s)}]: continue;
							case [{tok: CommentLine(s)}]: continue;
							case [{tok: BrClose}]: break;
							case [{tok: Const(c)}, {tok: DblDot, pos: p}]: {
									switch stream {
										case [exp = assignment()]: {
												// naive check for bad object format
												switch peek(0) {
													case {tok: Comma}: {}
													case {tok: Comment(s)}: {}
													case {tok: CommentLine(s)}: {}
													case {tok: BrClose}: {}
													case {tok: Line}: {
															var count = 1;
															while (true) {
																switch peek(count++) {
																	case {tok: BrClose}: break;
																	case {tok: Line}: continue;
																	case {tok: Comment(s)}: continue;
																	case {tok: CommentLine(s)}: continue;
																	case _:
																		errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' at object declaration.', p,
																			WrenLexer.lineCount));
																		break;
																}
															}
														}
													case _: errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' at object declaration.', p,
															WrenLexer.lineCount));
												}

												var hasQuotes = false;
												var key = switch c {
													case CIdent(s): s;
													case CString(s):
														hasQuotes = true;
														s;
													case CInt(s): s;
													case CFloat(s): s;
													case _: unexpected();
												}
												#if WREN_COMPILE
												callMethod(2, "addCore_(_,_)");
												#end
												objectFields.push({
													field: key,
													expr: exp,
													quotes: !hasQuotes ? QuoteStatus.Unquoted : QuoteStatus.Quoted
												});
											}
										case _: unexpected();
									}
								}
						}
					}

					{expr: EObjectDecl(objectFields), pos: p};
				}
		}
	}

	function callExpr() {
		return switch stream {
			case [exp = getPrimary()]: {
					var expr = exp;
					var isSuper = false;
					switch (last.tok) {
						case Kwd(KwdSuper): isSuper = true;
						case _: isSuper = false;
					}

					while (true) {
						switch stream {
							case [{tok: POpen, pos: p}]: {
									var args = [];

									#if WREN_COMPILE
									var signature = getEnclosingClass(this.vm.compiler).signature;
									var called:Signature = {
										name: signature.name,
										length: signature.length,
										type: SIG_GETTER,
										arity: 0
									};
									#end

									#if WREN_COMPILE
									called.type = SIG_METHOD;
									#end

									while (true) {
										switch stream {
											case [{tok: Comma}]: {
													while (true) {
														switch stream {
															case [{tok: Line}]: {}
															case _: break;
														}
													}

													continue;
												}
											case [{tok: Line}]: continue;
											case [exp = parseExpression()]: {
													args.push(exp);

													#if WREN_COMPILE
													this.vm.compiler.validateNumParameters(++called.arity);
													#end

													switch stream {
														case [{tok: Line, pos: p}]:
															if ((args.length > 0 && args[args.length - 2] != null)) {
																while (true) {
																	switch peek(0) {
																		case {tok: BkClose}: break;
																		case {tok: Line}: continue;
																		case _: break;
																	}
																}
															}
														case [{tok: Comma}]: {}
													}
												}
											case _: break;
										}
									}

									expr = {expr: ECall(expr, args, isSuper), pos: p};

									#if WREN_COMPILE
									if (signature.type == SIG_INITIALIZER) {
										if (called.type != SIG_METHOD) {
											this.vm.compiler.error("A superclass constructor must have an argument list.");
										}
										called.type = SIG_INITIALIZER;
										callSignature(CODE_SUPER_0, called);
									} else {
										callSignature(CODE_CALL_0, called);
									}
									#end

									switch stream {
										case [{tok: PClose}]: break;
										case _: errors.push(SError('Error at \'${peek(0)}\': Expect \')\' after arguments', p, WrenLexer.lineCount));
									}
								}
							case [{tok: Dot, pos: p}]: {
									switch stream {
										case [{tok: Const(CIdent(s)), pos: p}]: {
												expr = {expr: EField(expr, s, isSuper), pos: p};
											}
										case _:
											errors.push(SError('Error at \'${peek(0)}\': Expect property name after \'.\'', p, WrenLexer.lineCount));
											break;
									}
								}
							// ArrayGet[x]
							case [{tok: BkOpen, pos: p}]: {
									#if WREN_COMPILE
									var signature = getEnclosingClass(this.vm.compiler).signature;
									var called:Signature = {
										name: signature.name,
										length: signature.length,
										type: SIG_GETTER,
										arity: 0
									};

									this.vm.compiler.validateNumParameters(++called.arity);
									switch (peek(0).tok) {
										case Binop(OpAssign): {
												called.type = SIG_SUBSCRIPT_SETTER;
												this.vm.compiler.validateNumParameters(++called.arity);
											}
										case _:
									}
									#end

									var exp2 = parseExpression();

									#if WREN_COMPILE
									callSignature(CODE_CALL_0, called);
									#end

									switch stream {
										case [{tok: BkClose}]: {}
										case _: errors.push(SError('Error at \'${peek(0)}\': Expect \']\' after expression', p, WrenLexer.lineCount));
									}
									expr = {expr: EArray(expr, exp2), pos: p};
								}
							// Block arguments s.fn{}
							case [{tok: BrOpen, pos: p}]: {
									var isExpression = peek(0).tok != Line;

									#if WREN_COMPILE
									var signature = getEnclosingClass(this.vm.compiler).signature;
									var called:Signature = {
										name: signature.name,
										length: signature.length,
										type: SIG_GETTER,
										arity: 0
									};
									// Include the block argument in the arity.
									called.type = SIG_METHOD;
									called.arity++;
									var fnCompiler = Compiler.init(this, this.vm.compiler, false);
									// Make a dummy signature to track the arity.
									var fnSignature = {
										name: "",
										length: 0,
										type: SIG_METHOD,
										arity: 0
									};
									#end

									// Parse the parameter list, if any.
									switch stream {
										case [{tok: Binop(OpOr)}]: {
												var params = [];
												while (true) {
													switch stream {
														case [{tok: Comment(s)}]: continue;
														case [{tok: CommentLine(s)}]: continue;
														case [{tok: Comma}]: {
																while (true) {
																	switch stream {
																		case [{tok: Line}]: {}
																		case _: break;
																	}
																}

																continue;
															}
														case [{tok: Line}]: continue;
														case [expx = parseExpression()]: {
																params.push(expx);

																#if WREN_COMPILE
																this.vm.compiler.validateNumParameters(++fnSignature.arity);
																#end

																switch stream {
																	case [{tok: Line, pos: p}]:
																		if ((params.length > 0 && params[params.length - 2] != null)) {
																			while (true) {
																				switch peek(0) {
																					case {tok: Binop(OpOr)}: break;
																					case {tok: Line}: continue;
																					case {tok: BrClose}: break;
																					case _: break;
																				}
																			}
																		}
																	case [{tok: Comma}]: {}
																}
															}
														case _: break;
													}
												}

												#if WREN_COMPILE
												fnCompiler.fn.arity = fnSignature.arity;
												#end

												var exp2 = parseRepeat(parseExpression);

												#if WREN_COMPILE
												if (!isExpression) {
													// Implicitly return null in statement bodies.
													fnCompiler.emitOp(CODE_NULL);
												}
												fnCompiler.emitOp(CODE_RETURN);

												// Name the function based on the method its passed to.
												var blockName = "";

												blockName = called.toString();
												blockName += " block argument";

												fnCompiler.endCompiler(blockName);
												if (signature.type == SIG_INITIALIZER) {
													if (called.type != SIG_METHOD) {
														this.vm.compiler.error("A superclass constructor must have an argument list.");
													}
													called.type = SIG_INITIALIZER;
													callSignature(CODE_SUPER_0, called);
												} else {
													callSignature(CODE_CALL_0, called);
												}
												#end

												switch stream {
													case [{tok: BrClose}]: {
															switch stream {
																case [{tok: Comment(s)}]: {}
																case [{tok: Line}]: {}
																case [{tok: Eof}]: {}
																case _: unexpected();
															}
														}
													case _: errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' after expression', p,
															WrenLexer.lineCount));
												}

												expr = {expr: EBlockArg(expr, exp2, params), pos: p};
											}
										case [exp2 = parseRepeat(parseExpression)]: {
												#if WREN_COMPILE
												fnCompiler.fn.arity = fnSignature.arity;

												if (!isExpression) {
													// Implicitly return null in statement bodies.
													fnCompiler.emitOp(CODE_NULL);
												}
												fnCompiler.emitOp(CODE_RETURN);
												// Name the function based on the method its passed to.
												var blockName = "";

												blockName = called.toString();
												blockName += " block argument";

												fnCompiler.endCompiler(blockName);

												if (signature.type == SIG_INITIALIZER) {
													if (called.type != SIG_METHOD) {
														this.vm.compiler.error("A superclass constructor must have an argument list.");
													}
													called.type = SIG_INITIALIZER;
													callSignature(CODE_SUPER_0, called);
												} else {
													callSignature(CODE_CALL_0, called);
												}
												#end
												switch stream {
													case [{tok: BrClose}]: {
															switch stream {
																case [{tok: Comment(s)}]: {}
																case [{tok: Line}]: {}
																case [{tok: Eof}]: {}
																case _: unexpected();
															}
														}
													case _: errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' after expression', p,
															WrenLexer.lineCount));
												}

												expr = {expr: EBlockArg(expr, exp2, null), pos: p}
											}
									}
								}
							case _: {
									#if WREN_COMPILE
									var enclosingClass = getEnclosingClass(this.vm.compiler) != null ? getEnclosingClass(this.vm.compiler) : this.vm.compiler.enclosingClass;
									var signature = enclosingClass != null ? enclosingClass.signature : null;

									if (signature != null) {
										var called:Signature = {
											name: signature.name,
											length: signature.length,
											type: SIG_GETTER,
											arity: 0
										};

										if (signature.type == SIG_INITIALIZER) {
											if (called.type != SIG_METHOD) {
												this.vm.compiler.error("A superclass constructor must have an argument list.");
											}
											called.type = SIG_INITIALIZER;
											callSignature(CODE_SUPER_0, called);
										} else {
											callSignature(CODE_CALL_0, called);
										}
									} else {
										// switch expr.expr {
										// 	case EConst(CIdent(s)) | EConst(CInt(s)) | EConst(CFloat(s)) | EConst(CString(s)): {
										// 			trace(s);
										// 			this.vm.compiler.emitConstant(ObjString.newString(this.vm, s));
										// 		}
										// 	case _:
										// }
									}
									#end
									break;
								}
						}
					}
					return expr;
				}
		}
	}

	function variableDecl() {
		return switch stream {
			case [{tok: Const(CIdent(c)), pos: p}]: {
					switch stream {
						case [{tok: Binop(OpAssign)}, exp = parseExpression()]: {
								#if WREN_COMPILE
								// Now put it in scope.
								var symbol = this.vm.compiler.declareVariable(c);
								this.vm.compiler.defineVariable(symbol);
								#end
								{expr: EVars([{name: c, expr: exp, type: null}]), pos: exp.pos};
							}
					}
				}
		}
	}

	function ternary() {
		return switch stream {
			case [exp = orExpr()]: {
					return switch stream {
						case [{tok: Question}]: {
								#if WREN_COMPILE
								// Jump to the else branch if the condition is false.
								var ifJump = this.vm.compiler.emitJump(CODE_JUMP_IF);
								#end
								return switch stream {
									case [exp2 = orExpr(), {tok: DblDot}]:{
										#if WREN_COMPILE
										// Jump over the else branch when the if branch is taken.
										var elseJump = this.vm.compiler.emitJump(CODE_JUMP);
										this.vm.compiler.patchJump(ifJump);
										#end
										var exp3 = orExpr();
										#if WREN_COMPILE
										this.vm.compiler.patchJump(elseJump);
										#end
										var e = {expr: ETernary(exp, exp2, exp3), pos: exp3.pos};
										return e;
									}
									case _: unexpected();
								}
								
							}
						case _: exp;
					}
				}
		}
	}

	function orExpr() {
		return switch stream {
			case [exp = andExpr()]: {
					return switch stream {
						case [{tok: Binop(OpBoolOr), pos: p}]: {
								#if WREN_COMPILE
								// Skip the right argument if the left is true.
								var jump = this.vm.compiler.emitJump(CODE_OR);
								#end
								var right = andExpr();
								#if WREN_COMPILE
								this.vm.compiler.patchJump(jump);
								#end
								{expr: EBinop(OpBoolOr, exp, right), pos: right.pos};
							}
						case _: exp;
					}
				}
		}
	}

	function andExpr() {
		return switch stream {
			case [exp = equality()]: {
					return switch stream {
						case [{tok: Binop(OpBoolAnd), pos: p}]: {
								#if WREN_COMPILE
								// Skip the right argument if the left is true.
								var jump = this.vm.compiler.emitJump(CODE_AND);
								#end
								var right = parseExpression();
								#if WREN_COMPILE
								this.vm.compiler.patchJump(jump);
								#end
								{expr: EBinop(OpBoolAnd, exp, right), pos: right.pos};
							}
						case _: exp;
					}
				}
		}
	}

	function assignment() {
		return switch stream {
			case [exp = ternary()]: {
					#if WREN_COMPILE
					var field = Compiler.MAX_FIELDS;
					#end
					switch exp.expr {
						case EVars(d): {
								#if WREN_COMPILE
								if (d[0].name.charAt(0) == "_") {
									// is field
									// Initialize it with a fake value so we can keep parsing and minimize the
									// number of cascaded errors.
									field = Compiler.MAX_FIELDS;
									var enclosingClass = getEnclosingClass(this.vm.compiler);
									if (enclosingClass == null) {
										this.vm.compiler.error("Cannot reference a field outside of a class definition.");
									} else if (enclosingClass.isForeign) {
										this.vm.compiler.error("Cannot define fields in a foreign class.");
									} else if (enclosingClass.inStatic) {
										this.vm.compiler.error("Cannot use an instance field in a static method.");
									} else {
										// Look up the field, or implicitly define it.
										field = enclosingClass.fields.ensure(d[0].name);
										if (field >= Compiler.MAX_FIELDS) {
											this.vm.compiler.error('A class can only have ${Compiler.MAX_FIELDS} fields.');
										}
									}

									switch peek(0) {
										case {tok: Binop(OpAssign)}: {}
										case _: {
												#if WREN_COMPILE
												// If we're directly inside a method, use a more optimal instruction.
												if (this.vm.compiler.parent != null
													&& this.vm.compiler.parent.enclosingClass == enclosingClass) {
													this.vm.compiler.emitByteArg(CODE_LOAD_FIELD_THIS, field);
												} else {
													this.vm.compiler.loadThis();
													this.vm.compiler.emitByteArg(CODE_LOAD_FIELD_THIS, field);
												}
												#end
											}
									}
								} else if (d[0].name.charAt(0) == "_" && d[0].name.charAt(1) == "_") {
									// is static field
									var classCompiler = getEnclosingClassCompiler(this.vm.compiler);
									if (classCompiler == null) {
										this.vm.compiler.error("Cannot use a static field outside of a class definition.");
										return null;
									}

									// Look up the name in the scope chain.
									var tokenName = d[0].name;
									// If this is the first time we've seen this static field, implicitly
									// define it as a variable in the scope surrounding the class definition.
									if (classCompiler.resolveLocal(tokenName) == -1) {
										var symbol = classCompiler.declareVariable(tokenName);

										// Implicitly initialize it to null.
										classCompiler.emitOp(CODE_NULL);
										classCompiler.defineVariable(symbol);
									}
									// It definitely exists now, so resolve it properly. This is different from
									// the above resolveLocal() call because we may have already closed over it
									// as an upvalue.
									var variable = this.vm.compiler.resolveName(tokenName);
									// this.vm.compiler.bareName(canAssign, variable);

									switch peek(0) {
										case {tok: Binop(OpAssign)}: {}
										case _: this.vm.compiler.loadVariable(variable);
									}
								} else {
									// normal identity
									var tokenName = d[0].name;
									var variable = this.vm.compiler.resolveNonmodule(tokenName);
									if (variable.index != -1) {
										// bareName(compiler, canAssign, variable);
										switch peek(0) {
											case {tok: Binop(OpAssign)}: {}
											case _: this.vm.compiler.loadVariable(variable);
										}
									} else {
										// If we're inside a method and the name is lowercase, treat it as a method
										// on this.
										if (Compiler.isLocalName(tokenName) && getEnclosingClass(this.vm.compiler) != null) {
											this.vm.compiler.loadThis();
											// this.vm.compiler.namedCall(tokenName, false, CODE_CALL_0);
											var signature = this.vm.compiler.signatureFromToken(tokenName, SIG_GETTER);
											var called = {
												name: signature.name,
												length: signature.length,
												type: SIG_GETTER,
												arity: 0
											};
										} else {
											// Otherwise, look for a module-level variable with the name.
											variable.scope = SCOPE_MODULE;
											variable.index = this.module.variableNames.find(tokenName);
											if (variable.index == -1) {
												// Implicitly define a module-level variable in
												// the hopes that we get a real definition later.
												variable.index = this.module.declareVariable(this.vm, tokenName, WrenLexer.lineCount);

												if (variable.index == -2) {
													this.vm.compiler.error("Too many module variables defined.");
												}
											}

											switch peek(0) {
												case {tok: Binop(OpAssign)}: {}
												case _: this.vm.compiler.loadVariable(variable);
											}
										}
									}
								}
								#end
							}
						case _:
					}

					return switch stream {
						case [{tok: Binop(OpAssign), pos: p}]: {
								var value = ternary();
								return switch exp.expr {
									case EVars(d): {
											#if WREN_COMPILE
											if (d[0].name.charAt(0) == "_") {
												// If we're directly inside a method, use a more optimal instruction.
												if (this.vm.compiler.parent != null
													&& this.vm.compiler.parent.enclosingClass == getEnclosingClass(this.vm.compiler)) {
													this.vm.compiler.emitByteArg(CODE_STORE_FIELD_THIS, field);
												} else {
													this.vm.compiler.loadThis();
													this.vm.compiler.emitByteArg(CODE_STORE_FIELD, field);
												}
											} else if (d[0].name.charAt(0) == "_" && d[0].name.charAt(1) == "_") {
												// It definitely exists now, so resolve it properly. This is different from
												// the above resolveLocal() call because we may have already closed over it
												// as an upvalue.
												var tokenName = d[0].name;
												var variable = this.vm.compiler.resolveName(tokenName);
												// Emit the store instruction.
												switch (variable.scope) {
													case SCOPE_LOCAL:
														this.vm.compiler.emitByteArg(CODE_STORE_LOCAL, variable.index);
													case SCOPE_UPVALUE:
														this.vm.compiler.emitByteArg(CODE_STORE_UPVALUE, variable.index);
													case SCOPE_MODULE:
														this.vm.compiler.emitShortArg(CODE_STORE_MODULE_VAR, variable.index);
												}
											} else {
												// normal identity
												var tokenName = d[0].name;
												var variable = this.vm.compiler.resolveNonmodule(tokenName);
												if (variable.index != -1) {
													// bareName(compiler, canAssign, variable);
													switch (variable.scope) {
														case SCOPE_LOCAL:
															this.vm.compiler.emitByteArg(CODE_STORE_LOCAL, variable.index);
														case SCOPE_UPVALUE:
															this.vm.compiler.emitByteArg(CODE_STORE_UPVALUE, variable.index);
														case SCOPE_MODULE:
															this.vm.compiler.emitShortArg(CODE_STORE_MODULE_VAR, variable.index);
													}
												} else {
													// If we're inside a method and the name is lowercase, treat it as a method
													// on this.
													if (Compiler.isLocalName(tokenName) && getEnclosingClass(this.vm.compiler) != null) {
														this.vm.compiler.loadThis();
														// this.vm.compiler.namedCall(tokenName, false, CODE_CALL_0);
														var signature = this.vm.compiler.signatureFromToken(tokenName, SIG_GETTER);

														// Build the setter signature.
														signature.type = SIG_SETTER;
														signature.arity = 1;

														callSignature(CODE_CALL_0, signature);
													} else {
														// Otherwise, look for a module-level variable with the name.
														variable.scope = SCOPE_MODULE;
														variable.index = this.module.variableNames.find(tokenName);
														if (variable.index == -1) {
															// Implicitly define a module-level variable in
															// the hopes that we get a real definition later.
															variable.index = this.module.declareVariable(this.vm, tokenName, WrenLexer.lineCount);

															if (variable.index == -2) {
																this.vm.compiler.error("Too many module variables defined.");
															}
														}

														switch (variable.scope) {
															case SCOPE_LOCAL:
																this.vm.compiler.emitByteArg(CODE_STORE_LOCAL, variable.index);
															case SCOPE_UPVALUE:
																this.vm.compiler.emitByteArg(CODE_STORE_UPVALUE, variable.index);
															case SCOPE_MODULE:
																this.vm.compiler.emitShortArg(CODE_STORE_MODULE_VAR, variable.index);
														}
													}
												}
											}
											#end
											{expr: EBinop(OpAssign, exp, value), pos: value.pos};
										}
									case EField(_, name, isSuper): {
											#if WREN_COMPILE
											// Get the token for the method name.
											var signature = this.vm.compiler.signatureFromToken(name, SIG_GETTER);

											// Build the setter signature.
											signature.type = SIG_SETTER;
											signature.arity = 1;
											if (isSuper) {
												// Get the token for the method name.
												var instruction = CODE_SUPER_0;
												callSignature(instruction, signature);
											}
											#end
											{expr: EBinop(OpAssign, exp, value), pos: value.pos};
										}
									case _:
										errors.push(SError('Error at \'${peek(0)}\': Invalid assignment target', p, WrenLexer.lineCount));
										null;
								}
							}
						case _: exp;
					}
				}
		}
	}

	function unary() {
		return switch stream {
			case [{tok: Binop(OpSub), pos: p}]: {
					#if WREN_COMPILE
					// Call the operator method on the left-hand side.
					callMethod(0, "-");
					#end
					var exp = unary();
					{expr: EUnop(OpNeg, false, exp), pos: p};
				}
			case [{tok: Unop(OpNot), pos: p}]: {
					#if WREN_COMPILE
					// Call the operator method on the left-hand side.
					callMethod(0, "!");
					#end
					var exp = unary();
					{expr: EUnop(OpNot, false, exp), pos: p};
				}
			case [{tok: Unop(OpNegBits), pos: p}]: {
					#if WREN_COMPILE
					// Call the operator method on the left-hand side.
					callMethod(0, "~");
					#end
					var exp = unary();
					{expr: EUnop(OpNegBits, false, exp), pos: p};
				}

			case _: callExpr();
		}
	}

	function multiplication() {
		return switch stream {
			case [exp = unary()]: {
					switch stream {
						case [op = matchMult(), exp2 = unary()]: {
								infixOp(TokenDefPrinter.printBinop(op));
								{expr: EBinop(op, exp, exp2), pos: exp2.pos};
							}
						case _: exp;
					}
				}
		}
	}

	function addition() {
		return switch stream {
			case [exp = multiplication()]: {
					switch stream {
						case [op = matchAddition(), exp2 = multiplication()]: {
								infixOp(TokenDefPrinter.printBinop(op));
								{expr: EBinop(op, exp, exp2), pos: exp2.pos};
							}
						case _: exp;
					}
				}
		}
	}

	function comparison() {
		return switch stream {
			case [exp = addition()]: {
					switch stream {
						case [op = matchComparison(), exp2 = addition()]: {
								infixOp(TokenDefPrinter.printBinop(op));
								{expr: EBinop(op, exp, exp2), pos: exp2.pos};
							}
						case _: exp;
					}
				}
		}
	}

	function equality() {
		return switch stream {
			case [exp = comparison()]: {
					switch stream {
						case [op = matchEquality(), exp2 = comparison()]: {
								infixOp(TokenDefPrinter.printBinop(op));
								{expr: EBinop(op, exp, exp2), pos: exp2.pos};
							}
						case _: exp;
					}
				}
		}
	}

	function matchEquality() {
		return switch stream {
			case [{tok: Binop(OpEq)}]: {
					OpEq;
				}
			case [{tok: Binop(OpNotEq)}]: {
					OpNotEq;
				}
			case [{tok: Binop(OpOr)}]: {
					OpOr;
				}
			case [{tok: Binop(OpXor)}]: {
					OpXor;
				}
			case [{tok: Kwd(KwdIs)}]: {
					OpIs;
				}
		}
	}

	function matchComparison() {
		return switch stream {
			case [{tok: Binop(OpGt)}]: {
					OpGt;
				}
			case [{tok: Binop(OpGte)}]: {
					OpGte;
				}
			case [{tok: Binop(OpLt)}]: {
					OpLt;
				}
			case [{tok: Binop(OpLte)}]: {
					OpLte;
				}
			case [{tok: Binop(OpAnd)}]: {
					OpAnd;
				}
		}
	}

	function matchAddition() {
		return switch stream {
			case [{tok: Binop(OpAdd)}]: {
					OpAdd;
				}
			case [{tok: Binop(OpSub)}]: {
					OpSub;
				}
			case [{tok: Binop(OpShr)}]: {
					OpShr;
				}
			case [{tok: Binop(OpShl)}]: {
					OpShl;
				}
			case [{tok: Binop(OpInterval)}]: {
					OpInterval;
				}
			case [{tok: Binop(OpInterval2)}]: {
					OpInterval2;
				}
		}
	}

	function matchMult() {
		return switch stream {
			case [{tok: Binop(OpMult)}]: {
					OpMult;
				}
			case [{tok: Binop(OpDiv)}]: {
					OpDiv;
				}
			case [{tok: Binop(OpMod)}]: {
					OpMod;
				}
		}
	}

	inline function infixOp(op:String) {
		#if WREN_COMPILE
		var signature:Signature = {
			name: op,
			length: op.length,
			type: SIG_METHOD,
			arity: 1
		};
		callSignature(CODE_CALL_0, signature);
		#end
	}

	/**
	 * Compiles a method call with [signature] using [instruction].
	 */
	inline function callSignature(instruction:Code, signature:Signature) {
		#if WREN_COMPILE
		var symbol = this.vm.compiler.signatureSymbol(signature);
		this.vm.compiler.emitShortArg(cast(instruction + signature.arity, Code), symbol);
		if (instruction == CODE_SUPER_0) {
			// Super calls need to be statically bound to the class's superclass. This
			// ensures we call the right method even when a method containing a super
			// call is inherited by another subclass.
			//
			// We bind it at class definition time by storing a reference to the
			// superclass in a constant. So, here, we create a slot in the constant
			// table and store NULL in it. When the method is bound, we'll look up the
			// superclass then and store it in the constant slot.
			this.vm.compiler.emitShort(this.vm.compiler.addConstant(Value.NULL_VAL()));
		}
		#end
	}

	inline function callMethod(numArgs:Int, name:String) {
		#if WREN_COMPILE
		var symbol = this.vm.compiler.methodSymbol(name);
		this.vm.compiler.emitShortArg(cast(CODE_CALL_0 + numArgs, Code), symbol);
		#end
	}

	function parseList() {
		return switch stream {
			case [{tok: BkOpen, pos: p}]: {
					#if WREN_COMPILE
					// Instantiate a new list.
					this.vm.compiler.loadCoreVariable("List");
					callMethod(0, "new()");
					#end
					var args = [];
					while (true) {
						switch stream {
							case [{tok: Comma}]: {
									while (true) {
										switch stream {
											case [{tok: Line}]: {}
											case _: break;
										}
									}

									continue;
								}
							case [{tok: Line}]: continue;
							case [exp = parseExpression()]: {
									args.push(exp);
									#if WREN_COMPILE
									callMethod(1, "addCore_(_)");
									#end
									switch stream {
										case [{tok: Line, pos: p}]:
											if ((args.length > 0 && args[args.length - 2] != null)) {
												while (true) {
													switch peek(0) {
														case {tok: BkClose}: break;
														case {tok: Line}: break;
														case _:
															errors.push(SError('Error at \'${peek(0)}\': Expect \']\' after expression', p,
																WrenLexer.lineCount));
															break;
													}
												}
											} else {
												switch peek(0) {
													case {tok: BkClose}: break;
													case {tok: Line}: break;
													case _:
												}
											}

										case [{tok: Comma}]: {}
										case [{tok: BrClose}]: {}
										case _: continue;
									}
								}
							case [{tok: BkClose}]: break;
							case _:
								errors.push(SError('Error at \'${peek(0)}\': Expect \']\' after expression', p, WrenLexer.lineCount));
								break;
						}
					}

					return {expr: EArrayDecl(args), pos: p};
				}
		}
	}
}

private class StringParser extends WrenParser {
	public function new(s:String) {
		var source = byte.ByteData.ofString(s);
		super(source);
	}

	var numParens = 0;

	function parseInterpol() {
		return switch stream {
			case [{tok: Binop(OpMod)}, {tok: POpen, pos: p}]:
				{
					if (numParens < Compiler.MAX_INTERPOLATION_NESTING) {
						numParens += 1;
						var exp = parseExpression();
						switch stream {
							case [{tok: PClose}]: {}
							case _: errors.push(SError('Expect \')\' after interpolated expression', p, WrenLexer.lineCount));
						}
						return {expr: EParenthesis(exp), pos: p};
					}
					errors.push(SError('Interpolation may only nest ${Compiler.MAX_INTERPOLATION_NESTING} levels deep.', p, WrenLexer.lineCount));
					throw new hxparse.NoMatch<Dynamic>(curPos(), peek(0));
				}
			case _: {
					switch stream {
						case [token]: {
								{expr: EConst(CString(token.toString())), pos: token.pos};
							}
					}
				}
		}
	}

	public function exec() {
		return parseRepeat(parseInterpol);
	}
}
