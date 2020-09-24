package wrenparse;

import haxe.macro.Expr;
import wrenparse.Data;
import hxparse.Parser.parse as parse;

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
}

class WrenParser extends hxparse.Parser<hxparse.LexerTokenSource<Token>, Token> implements hxparse.ParserBuilder {
	public var source:String;
	public var errors:Array<Statement> = [];

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
			case [controlFlowStmt = parseConstrolFlow()]: controlFlowStmt;
			case [{tok: BrOpen, pos: p}, stmt = parseRepeat(parseStatements)]: {
					switch stream {
						case [{tok: BrClose}]: SBlock(stmt);
						case _:
							errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' ', p));
							null;
					}
				}
			case [expression = parseExpression()]: SExpression(expression, expression.pos);
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
							errors.push(SError('Error at ${peek(0)}: Expect a string after \'import\' \u2190', p));
							null;
					}

					var variables = [];
					while (true) {
						switch stream {
							case [{tok: Kwd(KwdFor), pos: p}]:
								{
									var isFin = false;
									while (true) {
										switch stream {
											case [{tok: Const(CIdent(name)), pos: p}]: variables.push(name);
											case [{tok: Comma, pos: p}]: {
													switch stream {
														case [{tok: Const(CIdent(name)), pos: p}]: variables.push(name);

														case _:
															errors.push(SError('Error at ${peek(0)}: Expect a constant after \'import "$importName" for ${variables.join(",")}\' \u2190',
																p));
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
												errors.push(SError('Error at ${peek(0)}: Expect a constant after \'import "$importName" for\'', p));
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

	function parseClass(isForeign:Bool = false):Statement {
		final def:Definition<ClassFlag, Array<ClassField>> = {
			name: "",
			doc: "",
			params: [],
			flags: [],
			data: []
		};

		if (isForeign)
			def.flags.push(HForeign);

		return switch stream {
			case [{tok: Kwd(KwdClass), pos: p}, {tok: Const(CIdent(s))}]: {
					def.name = s;
					var ext = switch stream {
						case [{tok: Kwd(KwdIs)}, {tok: Const(CIdent(ex))}]: {
								ex;
							}
						case _: null;
					}

					return switch stream {
						case [{tok: BrOpen, pos: p1}]: {
								if (ext != null) {
									def.flags.push(HExtends(ext));
								}
								return switch stream {
									case [fields = parseClassFields()]: {
											def.data = def.data.concat(fields);
											return switch stream {
												case [{tok: BrClose, pos: p1}]: return SClass(def, {min: p.min, max: p1.max, file: p.file});
												case _:
													errors.push(SError('unclosed block at class ${def.name} ${ext != null ? 'is $ext' : ''} { \u2190', p1));
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
		return switch stream {
			case [getterSetter = parseSetterGetter(name, true)]: getterSetter; // getterSetter;
			case [method = parseMethod(name, [AStatic])]: method;
			case _: throw new hxparse.NoMatch<Dynamic>(curPos(), peek(0));
		}
	}

	function parseForeignFields(name:String, isStatic:Bool = false):ClassField {
		var access = isStatic ? [AForeign, AStatic] : [AForeign];
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
		switch access {
			case [AForeign]:
				isForeign = true; // ignore
			case [AForeign, AStatic]:
				isForeign = true; // ignore
			case _:
				isForeign = false;
		}
		if (!isForeign) {
			return switch stream {
				case [{tok: BrOpen, pos: p2}, body = parseRepeat(parseStatements)]: {
						switch stream {
							case [{tok: BrClose}]: return {
									name: name,
									doc: null,
									access: access,
									kind: FMethod(params, body),
									pos: p2
								};
							case [{tok: Eof}]:
								errors.push(SError('unclosed block at ${[for (a in access) AccessPrinter.toString(a)].join(" ")} ${name}() \u2190', p2));
								null;
							case _: {
									errors.push(SError('unclosed block at ${[for (a in access) AccessPrinter.toString(a)].join(" ")} ${name}() \u2190', p2));
									null;
								}
						}
					}
				case _:
					errors.push(SError('Error at \'${peek(0)}\' : Expect \'{\' to begin a method body', null));
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
			case [{tok: Unop(op)}, {tok: BrOpen, pos: p}, code = parseRepeat(parseStatements)]: {
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
							errors.push(SError('Error at ${peek(0)}: unclosed block at operator ${TokenDefPrinter.toString(Unop(op))} \u2190', p));
							null;
					}
				}
			case [{tok: Binop(op)}]: {
					return switch stream {
						// op(other) { body }
						case [
							{tok: POpen},
							{tok: Const(CIdent(other))},
							{tok: PClose},
							{tok: BrOpen, pos: p},
							code = parseRepeat(parseStatements)
						]: {
								switch stream {
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
										errors.push(SError('Error at ${peek(0)}: unclosed block at operator ${TokenDefPrinter.toString(Binop(op))} \u2190',
											p));
										null;
								}
							}
						// - {}
						case [{tok: BrOpen, pos: p}, code = parseRepeat(parseStatements)]: {
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
												p));
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
						case [getterSetter = parseSetterGetter("")]: getterSetter; // getterSetter;
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
					var code = parseRepeat(parseStatements);
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
							errors.push(SError('Error at \'${peek(0)}\': Expect \'}\'', p));
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
					var code = parseRepeat(parseStatements);
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
							errors.push(SError('Error at \'${peek(0)}\': Expect \'}\'', p));
							return null;
					}
				}
		}
	}

	function parseSetterGetter(s:String, _static:Bool = false, _foreign:Bool = false) {
		var access = [];
		if (_foreign)
			access.push(AForeign);
		if (_static)
			access.push(AStatic);

		return switch stream {
			// setter
			case [{tok: Binop(OpAssign), pos: p2}]: {
					return switch stream {
						case [{tok: POpen}, {tok: Const(CIdent(c))}]: {
								switch stream {
									case [{tok: PClose, pos: p2}]: {
											var body = makeSetter(s, CIdent(c), p2, access);
											return body;
										}
									case _: {
											errors.push(SError('Error at ${peek(0)}: Expect \')\' at setter', p2));
											return null;
										}
								}
							}
						case [{tok: PClose, pos: p2}]: {
								errors.push(SError('Error at ${peek(0)}: Expect variable name', p2));
								return null;
							}
						case _: {
								errors.push(SError('Error at ${peek(0)}: Expect variable name', p2));
								return null;
							}
					}
				}
			// // method (with-args)
			// case [{tok: POpen}, params = parseRepeat(parseParamNames), {tok: PClose, pos: p2}]: {
			// 		switch stream {
			// 			case [{tok: BrOpen, pos: p}]: {
			// 					var data = makeMethod(s, params, p2, access);
			// 					data;
			// 				}
			// 		}
			// 	}
			// method (no-args) && Getter
			case [{tok: BrOpen, pos: p0}]: {
					if (_foreign) {
						errors.push(SError('Error at \'{\': foreign field \'$s\' cannot have body', p0));
						null;
					} else {
						var data = null;
						switch stream {
							// method (no-args)
							case [{tok: Line, pos: p}]: {
									data = makeMethod(s, [], p, access);
									data;
								}
							// Getter
							case [exp = parseExpression(), {tok: BrClose, pos: p}]: {
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
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at getter $s', p0));
						null;
					}
				}
			case [{tok: Eof, pos: p0}]: {
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
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at getter $s', p0));
						null;
					}
				}
		}
	}

	function makeMethod(name, args:Array<Constant>, pos, access:Array<Access>) {
		var code = parseRepeat(parseStatements);
		switch stream {
			case [{tok: BrClose}]:
				{}
			case [{tok: Eof}]:
				errors.push(SError('Error: Expect \'}\', unclosed block at method ${name} \u2190', pos));
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

	function makeSetter(name, arg, pos, access:Array<Access>) {
		var isForeign = switch access {
			case [AForeign, AStatic]: true;
			case [AForeign]: true;
			case _: false;
		};

		return switch stream {
			case [{tok: BrOpen, pos: p}]:
				{
					if (isForeign) {
						errors.push(SError('Error at \'{\': foreign field cannot have body ', p));
						return null;
					} else {
						var code = parseRepeat(parseStatements);
						switch stream {
							case [{tok: BrClose}]:
							case [{tok: Eof}]:
								errors.push(SError('unclosed block at setter ${name} \u2190', p));
								return null;
							case _: {
									errors.push(SError('unclosed block at setter ${name} \u2190', p));
									return null;
								}
						}
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
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at setter $name', p0));
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
						errors.push(SError('Error at \'${peek(0)}\': Expect \'{\' at setter $name', p0));
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
				errors.push(SError('invalid argument ${KeywordPrinter.toString(k)} at $p', p));
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

	function parseConstrolFlow() {
		return switch stream {
			case [{tok: Kwd(KwdIf)}, {tok: POpen}, exp = parseExpression(), {tok: PClose}]: {
					switch stream {
						case [{tok: BrOpen, pos: p}, body = parseRepeat(parseStatements)]:
							{
								while (true) {
									switch stream {
										case [{tok: Kwd(KwdBreak), pos: p}]: body.push(SExpression({expr: EBreak, pos: p}, p));
										case [{tok: BrClose}]: break;
										case [{tok: Line}]: continue;
										case [{tok: Comment(s)}]: continue;
										case [{tok: CommentLine(s)}]: continue;
										case _:
											errors.push(SError('Expect \'}\' at ${peek(0)}', p));
											break;
									}
								}

								switch stream {
									case [{tok: Kwd(KwdElse), pos: p}]: {
											var elseBody = [];
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
																	errors.push(SError('Expect \'}\' at ${peek(0)}', p));
																	break;
															}
														}
													}
												case [exp = parseRepeat(parseStatements)]: elseBody.concat(parseRepeat(parseStatements));
											}

											return SIf(exp, body, elseBody);
										}
									case _:
								}

								return SIf(exp, body, []);
							}
						case [body = parseExpression()]:
							{
								var elseBody = [];
								while (true) {
									switch stream {
										case [{tok: Kwd(KwdElse), pos: p}]: {
												switch stream {
													case [{tok: Kwd(KwdIf)}]: elseBody.push(parseConstrolFlow());
													case [{tok: BrOpen}]: elseBody.push(parseStatements());
													case _: elseBody.push(SExpression(parseExpression(), p));
												}
											}
										case [{tok: Comment(s)}]: continue;
										case [{tok: CommentLine(s)}]: continue;
										case [{tok: Line}]: break;
									}
								}
								return SIf(exp, [SExpression(body, body.pos)], elseBody);
							}

							// case _ : unexpected();
					}
					// var body = parseRepeat(parseStatements);
					// trace(body);
					// switch stream {
					// 	case [{tok: Kwd(KwdElse), pos:p}]: {
					// 			var elseBody = null;
					// 			trace(peek(0));
					// 			switch peek(0){
					// 				case {tok:Kwd(KwdIf)}:{
					// 					elseBody = [parseConstrolFlow()];
					// 				}
					// 				case _:{
					// 					elseBody = parseRepeat(parseStatements);

					// 					while (true) {

					// 						switch stream {
					// 							case [{tok: Kwd(KwdBreak), pos: p}]: body.push(SExpression({expr: EBreak, pos: p}, p));
					// 							case [{tok: BrClose}]: break;
					// 							case [{tok: Line}]: continue;
					// 							case _:
					// 								errors.push(SError('Expect \'}\' at ${peek(0)}', p));
					// 								break;
					// 						}
					// 					}
					// 				}
					// 			}

					// 			return SIf(exp, body, elseBody);
					// 		}
					// }
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
					var body = parseRepeat(parseStatements);
					while (true) {
						switch stream {
							case [{tok: Kwd(KwdBreak), pos: p}]: body.push(SExpression({expr: EBreak, pos: p}, p));
							case [{tok: BrClose}]: break;
							case [{tok: Line}]: continue;
							case _:
								errors.push(SError('Expect \'}\' at ${peek(0)}', p));
								break;
						}
					}
					return SFor({expr: EFor(exp, {expr: EConst(CIdent(s)), pos: p}), pos: p}, body);
				}
			case [
				{tok: Kwd(KwdWhile)},
				{tok: POpen},
				exp = parseExpression(),
				{tok: PClose},
				{tok: BrOpen, pos: p}
			]: {
					var body = parseRepeat(parseStatements);
					while (true) {
						switch stream {
							case [{tok: Kwd(KwdBreak), pos: p}]: body.push(SExpression({expr: EBreak, pos: p}, p));
							case [{tok: BrClose}]: break;
							case [{tok: Line}]: continue;
							case _:
								errors.push(SError('Expect \'}\' at ${peek(0)}', p));
								break;
						}
					}
					return SWhile({expr: EWhile(exp, null, true), pos: p}, body);
				}
		}
	}

	function parseExpression() {
		return switch stream {
			case [exp = assignment()]: exp;
				// case [map = parseMap()]: map;
		}
	}

	function getPrimary() {
		return switch stream {
			case [{tok: Const(c), pos: p}]: {
					switch c {
						case CIdent(s): {expr: EVars([{name: s, expr: null, type: null}]), pos: p};
						case _: {expr: EConst(c), pos: p};
					}
				}
			case [{tok: Kwd(KwdNull), pos: p}]: {expr: ENull, pos: p};
			case [{tok: Kwd(KwdTrue), pos: p}]: {expr: EConst(CIdent("true")), pos: p};
			case [{tok: Kwd(KwdFalse), pos: p}]: {expr: EConst(CIdent("false")), pos: p};
			case [{tok: POpen, pos: p}, exp = parseExpression()]: {
					switch stream {
						case [{tok: PClose}]: {}
						case _: errors.push(SError('Expect \')\' after expression', p));
					}

					{expr: EParenthesis(exp), pos: p};
				}
			case [list = parseList()]: list;
			case [map = parseMap()]: map;
		}
	}

	function parseMap() {
		return switch stream {
			case [{tok: BrOpen, pos: p}]: {
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
																		errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' at object declaration.', p));
																		break;
																}
															}
														}
													case _: errors.push(SError('Error at \'${peek(0)}\': Expect \'}\' at object declaration.', p));
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
					while (true) {
						switch stream {
							case [{tok: POpen, pos: p}]: {
									var args = [];
									while(true){
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
											
													switch stream {
														case [{tok: Line, pos: p}]:
															if((args.length > 0 && args[args.length - 2] != null)){
																while(true){
																	switch peek(0){
																		case {tok:BkClose}: break;
																		case {tok:Line}: continue;
																		case _: errors.push(SError('Error at \'${peek(0)}\': Expect \')\' after arguments', p));break;
																	}
																}
															}
														case [{tok: Comma}]: {}
													}
												}
											case _: break;
										}
									}
									expr = {expr: ECall(exp, args), pos: p};
									switch stream {
										case [{tok: PClose}]: break;
										case _: errors.push(SError('Error at \'${peek(0)}\': Expect \')\' after arguments', p));
									}
										
								}
							case [{tok: Dot, pos: p}]: {
									switch stream {
										case [{tok: Const(CIdent(s)), pos: p}]: expr = {expr: EField(exp, s), pos: p};
										case _:
											errors.push(SError('Error at \'${peek(0)}\': Expect property name after \'.\'', p));
											break;
									}
								}
							// ArrayGet[x]	
							case [{tok: BkOpen, pos: p}, exp2 = parseExpression()]: {
									switch stream {
										case [{tok: BkClose}]: {}
										case _: errors.push(SError('Error at \'${peek(0)}\': Expect \']\' after expression', p));
									}
									expr = {expr: EArray(exp, exp2), pos:p};
									
							}
							// case [{tok:CommentLine(s)}]: break;
							// case [{tok:Line}]: break;
							case _: break;
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
						case [{tok: Question}, exp2 = orExpr(), {tok: DblDot}, exp3 = orExpr()]: {
								var e = {expr: ETernary(exp, exp2, exp3), pos: exp3.pos};
								return e;
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
						case [{tok: Binop(OpBoolOr), pos: p}, right = andExpr()]: {expr: EBinop(OpBoolOr, exp, right), pos: right.pos};
						case _: exp;
					}
				}
		}
	}

	function andExpr() {
		return switch stream {
			case [exp = equality()]: {
					return switch stream {
						case [{tok: Binop(OpBoolAnd), pos: p}, right = parseExpression()]: {expr: EBinop(OpBoolAnd, exp, right), pos: right.pos};
						case _: exp;
					}
				}
		}
	}

	function assignment() {
		return switch stream {
			case [exp = ternary()]: {
					return switch stream {
						case [{tok: Binop(OpAssign), pos: p}, value = ternary()]: {
								return switch exp.expr {
									case EVars(_): {expr: EBinop(OpAssign, exp, value), pos: value.pos};
									case EField(_, _): {expr: EBinop(OpAssign, exp, value), pos: value.pos};
									case _:
										errors.push(SError('Error at \'${peek(0)}\': Invalid assignment target', p));
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
			case [{tok: Binop(OpSub), pos: p}, exp = unary()]: {
					{expr: EUnop(OpNeg, false, exp), pos: p};
				}
			case [{tok: Unop(OpNot), pos: p}, exp = unary()]: {
					{expr: EUnop(OpNot, false, exp), pos: p};
				}
			case [{tok: Unop(OpNegBits), pos: p}, exp = unary()]: {
					{expr: EUnop(OpNegBits, false, exp), pos: p};
				}
			case _: callExpr();
		}
	}

	function multiplication() {
		return switch stream {
			case [exp = unary()]: {
					switch stream {
						case [op = matchMult(), exp2 = unary()]: {expr: EBinop(op, exp, exp2), pos: exp2.pos};
						case _: exp;
					}
				}
		}
	}

	function addition() {
		return switch stream {
			case [exp = multiplication()]: {
					switch stream {
						case [op = matchAddition(), exp2 = multiplication()]: {expr: EBinop(op, exp, exp2), pos: exp2.pos};
						case _: exp;
					}
				}
		}
	}

	function comparison() {
		return switch stream {
			case [exp = addition()]: {
					switch stream {
						case [op = matchComparison(), exp2 = addition()]: {expr: EBinop(op, exp, exp2), pos: exp2.pos};
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

	function parseList() {
		return switch stream {
			case [{tok: BkOpen, pos: p}]: {
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
									switch stream {
										case [{tok: Line, pos: p}]:
											if((args.length > 0 && args[args.length - 2] != null)){
												while(true){
													switch peek(0){
														case {tok:BkClose}: break;
														case {tok:Line}: continue;
														case _: errors.push(SError('Error at \'${peek(0)}\': Expect \']\' after expression', p));break;
													}
												}
											}
										case [{tok: Comma}]: {}
									}
								}
							case _: break;
						}
					}
					switch stream {
						case [{tok: BkClose}]: {};
						case _: errors.push(SError('Error at \'${peek(0)}\': Expect \']\' after expression', p));
					}
					return {expr: EArrayDecl(args), pos: p};
				}
		}
	}
}
