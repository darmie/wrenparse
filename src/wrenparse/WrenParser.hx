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

enum SmallType {
	SNull;
	SBool(b:Bool);
	SFloat(f:Float);
	SString(s:String);
}

enum abstract SkipState(Int) {
	var Consume = 0; // consume current branch
	var SkipBranch = 1; // skip until next #elsif/#else
	var SkipRest = 2; // skip until #end
}

class WrenParser extends hxparse.Parser<hxparse.LexerTokenSource<Token>, Token> implements hxparse.ParserBuilder {
	public var source:String;

	public function new(input:byte.ByteData, sourceName:String = "main") {
		source = sourceName;
		var lexer = new WrenLexer(input, sourceName);
		var ts = new hxparse.LexerTokenSource(lexer, WrenLexer.tok);
		super(ts);
	}

	public function parse():Dynamic {
		return switch stream {
			case [{tok: Eof}]: CodeDef.Eof;
			case _: parseModule();
		};
	}

	function parseModule() {
		var code = [];

		while (true) {
			switch stream {
				case [{tok: Kwd(KwdImport), pos: p1}]:
					{
						code.push(parseImport(p1));
					}
				case [{tok: Kwd(KwdClass), pos: p}]:
					{
						code.push(parseClass(p, false));
					}
				case [{tok: Kwd(KwdForeign), pos: p}, {tok: Kwd(KwdClass), pos: p}]:
					{
						code.push(parseClass(p, true));
					}
				case [{tok: Comment(s)}]:
					continue;
				case [{tok: CommentLine(s)}]:
					continue;
				case [{tok: Line}]:
					code = code.concat(parseModule());
				case [{tok: Eof}]:
					break;
				case _:
					code.push(parseStatements());
			}
		}

		return code;
	}

	function parseImport(pos):Dynamic {
		var importName = switch stream {
			case [{tok: Const(CString(name)), pos: p}]: name;
			case _: unexpected();
		}
		var variables = [];
		while (true) {
			switch stream {
				case [{tok: Kwd(KwdFor)}]:
					{
						var isFin = false;
						while (true) {
							switch stream {
								case [{tok: Const(CIdent(name)), pos: p}]: variables.push(name);
								case [{tok: Comma, pos: p}]: {
										switch stream {
											case [{tok: Const(CIdent(name)), pos: p}]: variables.push(name);
											case _: unexpected();
										}
									}
								case [{tok: Line, pos: p}]: isFin = true;
								case [{tok: Eof, pos: p}]: isFin = true;
								case _: unexpected();
							}
							if (isFin)
								break;
						}
					}
				case [{tok: Line, pos: p}]:
					return EImport(importName, INormal);
				case [{tok: Eof, pos: p}]:
					break;
				case _:
					break;
			}
		}
		if (variables.length > 0) {
			return EImport(importName, IWithVars(variables));
		} else {
			return EImport(importName, INormal);
		}
	}

	function parseClass(pos, isForeign) {
		final def:Definition<ClassFlag, Array<ClassField>> = {
			name: "",
			doc: "",
			params: [],
			flags: [],
			data: []
		};

		if (isForeign == true) {
			def.flags.push(HForeign);
		}

		switch stream {
			case [{tok: Const(CIdent(s)), pos: p1}]:
				{
					def.name = s;
					switch stream {
						case [{tok: BrOpen}, fields = null]: {
								def.data = fields;
								switch stream {
									case [{tok: BrClose}]: EClass(def);
									case _: throw 'unclosed block at class ${def.name} { \u2190';
								}
							}
						case [{tok: Kwd(KwdIs)}]: {
								switch stream {
									case [{tok: Const(CIdent(s)), pos: p1}, {tok: BrOpen},]: {
											def.flags.push(HExtends(s));
											def.data = [];
											while (true) {
												var f = parseClassField();
												if (f == null) {
													switch stream {
														case [{tok: Line}]: continue;
														case _: {
																break;
															}
													}
												} else {
													def.data.push(f);
												}
											}
											switch stream {
												case [{tok: BrClose}]: EClass(def);
												case _: throw 'unclosed block at class ${def.name} is $s { \u2190';
											}
										}
									case _: unexpected();
								}
							}
						case _: throw 'expected { after "class ${def.name}"';
					}
				}
			case _:
				unexpected();
		}

		return EClass(def);
	}

	function parseClassField() {
		return switch stream {
			case [{tok: Kwd(KwdConstruct)}]: parseMethodWithAccess([AConstructor]);
			case [{tok: Kwd(KwdStatic)}]: parseMethodWithAccess([AStatic]);
			case [{tok: Kwd(KwdForeign)}, {tok: Kwd(KwdStatic)}]: parseMethodWithAccess([AForeign, AStatic]);
			case [{tok: Const(CIdent(s))}]: {
					switch stream {
						// setter
						case [
							{tok: Binop(op)},
							{tok: POpen},
							param = parseParamNames(),
							{tok: PClose, pos: p2}
						]: {
								try {
									makeSetter(s, param, p2);
								} catch (e:haxe.Exception) {
									throw e;
								}
							}
						// method (with-args)
						case [{tok: POpen}, params = parseRepeat(parseParamNames), {tok: PClose, pos: p2}]: {
								switch stream {
									case [{tok: BrOpen}]: {
											makeMethod(s, params, p2);
										}
								}
							}
						// method (no-args) && Getter
						case [{tok: BrOpen}]: {
								var data = null;
								switch stream {
									// method (no-args)
									case [{tok: Line, pos: p}]: {
											data = makeMethod(s, [], p);
										}
									// Getter
									case [{tok: Const(c), pos: p}]: {
											data = makeGetter(s, EStatement([parseExpr({expr: EConst(c), pos: p})]), p);
											return switch stream {
												case [{tok: BrClose}]: data;
												case _: throw 'unclosed block at field $s';
											}
										}
								}
							}
					}
				}
			case [p = parseOpOverload()]: p;
			case [{tok: Line}]: parseClassField();
			case _: null;
		}
	}

	function parseOpOverload() {
		return switch stream {
			// op { body }
			case [{tok: Unop(op)}, {tok: BrOpen, pos: p}]: {
					var code = [];
					var name = TokenDefPrinter.toString(Unop(op));
					while (true) {
						code.push(getCodeDef());
						switch stream {
							case [{tok: BrClose}]:
								{
									break;
								}
							case [{tok: CommentLine(s)}]:
								continue;
							case [{tok: Eof}]:
								throw 'unclosed block at operator ${name} \u2190';
						}
					}
					return {
						name: name,
						doc: null,
						access: [],
						kind: FOperator(FPrefixOp(op, code)),
						pos: p
					}
				}
			case [{tok: Binop(op)}]: {
					return switch stream {
						// op(other) { body }
						case [{tok: POpen}, {tok: Const(CIdent(other))}, {tok: PClose}, {tok: BrOpen, pos: p}]: {
								var code = [];
								var name = TokenDefPrinter.toString(Binop(op));
								while (true) {
									code.push(getCodeDef());
									switch stream {
										case [{tok: BrClose}]:
											{
												break;
											}
										case [{tok: CommentLine(s)}]:
											continue;
										case [{tok: Eof}]:
											throw 'unclosed block at operator ${name} \u2190';
									}
								}
								return {
									name: name,
									doc: null,
									access: [],
									kind: FOperator(FInfixOp(op, CIdent(other), code)),
									pos: p
								}
							}
						case [{tok: BrOpen, pos: p}]: {
								if (op == OpSub) {
									var code = [];
									var name = "-";
									while (true) {
										code.push(getCodeDef());
										switch stream {
											case [{tok: BrClose}]:
												{
													break;
												}
											case [{tok: CommentLine(s)}]:
												continue;
											case [{tok: Eof}]:
												throw 'unclosed block at operator ${name} \u2190';
										}
									}
									return {
										name: name,
										doc: null,
										access: [],
										kind: FOperator(FPrefixOp(OpNeg, code)),
										pos: p
									}
								} else {
									throw unexpected();
								}
							}
					}
				}

			case [
				{tok: Interpol},
				{tok: Const(CIdent(other))},
				{tok: PClose},
				{tok: BrOpen, pos: p}
			]: {
					var code = [];
					var name = "%";
					while (true) {
						code.push(getCodeDef());
						switch stream {
							case [{tok: BrClose}]:
								{
									break;
								}
							case [{tok: CommentLine(s)}]:
								continue;
							case [{tok: Eof}]:
								throw 'unclosed block at operator ${name} \u2190';
						}
					}
					return {
						name: name,
						doc: null,
						access: [],
						kind: FOperator(FInfixOp(OpMod, CIdent(other), code)),
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
					var code = [];
					var name = "is";
					while (true) {
						code.push(getCodeDef());
						switch stream {
							case [{tok: BrClose}]:
								{
									break;
								}
							case [{tok: CommentLine(s)}]:
								continue;
							case [{tok: Eof}]:
								throw 'unclosed block at operator ${name} \u2190';
						}
					}
					return {
						name: name,
						doc: null,
						access: [],
						kind: FOperator(FInfixOp(OpIs, CIdent(other), code)),
						pos: p
					}
				}
			// Subscript ops, myclass[value] or  myClass[value] = (other)
			case [{tok: BkOpen}]: {
					var subscript_params = [];
					var code = [];
					var pos = null;
					var arg = null;
					while (true) {
						switch stream {
							case [{tok: Const(CIdent(s))}]: subscript_params.push(CIdent(s));
							case [{tok: Comma}]: continue;
							case [{tok: BkClose}]: break;
						}
					}
					switch stream {
						// setter
						case [{tok: Binop(OpAssign)},{tok: POpen}, {tok: Const(CIdent(other))}, {tok: PClose}, {tok: BrOpen, pos: p}]: {
								pos = p;
								arg = CIdent(other);
								while (true) {
									code.push(getCodeDef());
									switch stream {
										case [{tok: BrClose}]:
											{
												break;
											}
										case [{tok: CommentLine(s)}]:
											continue;
										case [{tok: Eof}]:
											throw 'unclosed block at operator [${subscript_params.join(",")}]=($other) \u2190';
									}
								}
							}
						// getter
						case [{tok: BrOpen, pos: p}]: {
								pos = p;
								while (true) {
									code.push(getCodeDef());
									switch stream {
										case [{tok: BrClose}]:
											{
												break;
											}
										case [{tok: CommentLine(s)}]:
											continue;
										case [{tok: Eof}]:
											throw 'unclosed block at operator [${subscript_params.join(",")}] \u2190';
									}
								}
							}
					}

					return return {
						name: "",
						doc: null,
						access: [],
						kind: FOperator(FSubscriptOp(subscript_params, arg, code)),
						pos: pos
					}
				}
		}
	}

	function makeMethod(name, args:Array<Constant>, pos) {
		var code = [];

		while (true) {
			code.push(getCodeDef());
			switch stream {
				case [{tok: BrClose}]:
					{
						break;
					}
				case [{tok: CommentLine(s)}]:
					continue;
				case [{tok: Eof}]:
					throw 'unclosed block at method ${name} \u2190';
			}
		}

		return {
			name: name,
			doc: null,
			access: [],
			kind: FMethod(args, code),
			pos: pos
		}
	}

	function makeGetter(name, def:CodeDef, pos) {
		return {
			name: name,
			doc: null,
			access: [],
			kind: FGetter(def),
			pos: pos
		}
	}

	function makeSetter(name, arg, pos) {
		return switch stream {
			case [{tok: BrOpen}]:
				{
					var code = parseRepeat(getCodeDef);
					switch stream {
						case [{tok: BrClose}]:
						case [{tok: Eof}]:
							throw 'unclosed block at setter ${name} \u2190';
						case _: {
								throw 'unclosed block at setter ${name} \u2190';
							}
					}
					return {
						name: name,
						doc: null,
						access: [],
						kind: FSetter(arg, code),
						pos: pos
					};
				}
		}
	}

	function getCodeDef() {
		return switch stream {
			case [{tok: Kwd(KwdImport), pos: p1}]:
				{
					parseImport(p1);
				}
			case [{tok: Kwd(KwdClass), pos: p}]:
				{
					parseClass(p, false);
				}
			case [{tok: Kwd(KwdForeign)}, {tok: Kwd(KwdClass), pos: p}]:
				{
					parseClass(p, true);
				}
			case [{tok: Line}]:
				parseStatements();
			case [{tok: CommentLine(s)}]: parseStatements();
			case [exp = getExpr()]: EStatement([exp]);
		}
	}

	function parseParamNames() {
		return switch stream {
			case [{tok: Const(x), pos: p}]: {
					switch stream {
						case [{tok: Line}]: {} // ignore
						case _:
					}
					switch x {
						case CIdent(s): CIdent(s);
						case _: throw 'invalid argument at $p';
					}
				}
			case [{tok: Kwd(k), pos: p}]: throw 'invalid argument ${KeywordPrinter.toString(k)} at $p';
			case [{tok: Comma}]: {
					switch stream {
						case [{tok: Line}]: {} // ignore
						case _:
					}
					parseParamNames();
				}
			case [{tok: Line}]: null;
		}
	}

	function parseMethodWithAccess(access:Array<Access>) {
		return switch stream {
			case [{tok: Const(CIdent(s))}]: {
					var params = [];
					var isForeign = false;
					switch stream {
						case [{tok: POpen}, _params = parseRepeat(parseParamNames)]: {
								while (true) {
									switch stream {
										case [{tok: PClose, pos: p2}]: params = _params;
										case [{tok: Line}]: // ignore
										case _: break;
									}
								}
							}
						case [{tok: Line}]: // ignore
						case _: {
								switch access {
									case [AConstructor]: {
											throw "Error at 'new': A constructor cannot be a getter.";
										}
									case [AConstructor, AStatic]: unexpected();
									case [AStatic, AConstructor]: unexpected();
									case [AStatic, AForeign]: unexpected();
									case [AForeign, AStatic]: isForeign = true;
									case [AForeign]: isForeign = true;
									case _:
								}
							}
					}
					var cName = s;

					switch stream {
						case [{tok: BrOpen, pos: p2}]: {
								var code = [];

								while (true) {
									switch stream {
										case [{tok: Kwd(KwdImport), pos: p1}]:
											{
												if (!isForeign) {
													code.push(parseImport(p1));
												} else {
													throw "Foreign methods can't have body";
												}
											}
										case [{tok: Kwd(KwdClass), pos: p}]:
											{
												if (!isForeign) {
													code.push(parseClass(p, false));
												} else {
													throw "Foreign methods can't have body";
												}
											}
										case [{tok: Kwd(KwdForeign)}, {tok: Kwd(KwdClass), pos: p}]:
											{
												if (!isForeign) {
													code.push(parseClass(p, true));
												} else {
													throw "Foreign methods can't have body";
												}
											}
										case [{tok: Line}]:
											if (!isForeign) {
												if (peek(0).toString() != "}") {
													code.push(parseStatements());
													continue;
												}
											} else {
												throw "Foreign methods can't have body";
											}
										case [{tok: BrClose}]: break;
										case [{tok: Eof}]:
											throw 'unclosed block at ${[for (a in access) AccessPrinter.toString(a)].join(" ")} ${cName}() \u2190';
										case _: {
												throw 'unclosed block at ${[for (a in access) AccessPrinter.toString(a)].join(" ")} ${cName}() \u2190';
											}
									}
								}

								return {
									name: cName,
									doc: null,
									access: access,
									kind: FMethod(params, code),
									pos: p2
								};
							}
					}
				}
		}
	}

	function getExpr() {
		return switch stream {
			case [{tok: Kwd(KwdSuper), pos: p}]: parseExpr({expr: EConst(CIdent("super")), pos: p});
			case [{tok: Kwd(KwdThis), pos: p}]: parseExpr({expr: EConst(CIdent("this")), pos: p});
			case [{tok: Const(c), pos: p2}]: parseExpr({expr: EConst(c), pos: p2});
			case [{tok: Kwd(KwdNull), pos: p}]: {expr: ENull, pos: p};
			case [{tok: Kwd(KwdFalse), pos: p}]: parseExpr({expr: EConst(CIdent("false")), pos: p});
			case [{tok: Kwd(KwdTrue), pos: p}]: parseExpr({expr: EConst(CIdent("true")), pos: p});
			case [{tok: POpen}, exp = getExpr(), {tok: PClose, pos: p}]: {expr: EParenthesis(exp), pos: p};
			case [{tok: BkOpen, pos: p4}]:
				{ // list
					var pos = null;
					var exp = null;
					var exps:Array<wrenparse.Data.Expr> = [];
					while (true) {
						switch stream {
							case [{tok: Line}]: {
									switch stream {
										case [{tok: BkClose, pos: p5}]: break;
										case [{tok: Comma}]: throw "Expect ']' at list statement";
										case _: continue;
									}
								}
							case [{tok: BkClose, pos: p5}]: break;
							case [{tok: Comma}]: {
									switch stream {
										case [{tok: Line}]: {} // ignore
										case _: continue;
									}
								}
							case [{tok: Kwd(KwdNull), pos: p}]:
								exps.push({expr: ENull, pos: p});
								pos = p;
							case [{tok: Const(c), pos: p6}]:
								exps.push(parseExpr({expr: EConst(c), pos: p6}));
								pos = p6;
								while (true) {
									switch peek(0) {
										case {tok: Line}: {
												if (peek(1).tok == Comma) {
													throw "Error at newline: unclosed array;  Expect ']'";
												}
												switch peek(1) {
													case {tok: Const(c)}: throw "Error at newline: unclosed array;  Expect ']'";
													case _: break;
												}
											}
										case {tok: BkClose}: break;
										case {tok: Comma}: break;
										case _: break;
									}
								}
							case _: {
									throw "Error at newline: unclosed array;  Expect ']'";
								}
						}
					}
					return parseExpr({expr: EArrayDecl(exps), pos: p4});
				}
			case [{tok: BrOpen, pos: p3}]: {
					var map = parseMap(p3);
					return parseExpr(map);
				}
			// unary ops
			case [{tok: Binop(OpSub), pos: p}, exp = getExpr()]: {expr: EUnop(OpNeg, false, exp), pos: p};
			case [{tok: Unop(OpNegBits), pos: p}, exp = getExpr()]: {expr: EUnop(OpNegBits, false, exp), pos: p};
			case [{tok: Unop(OpNot), pos: p}, exp = getExpr()]: {expr: EUnop(OpNot, false, exp), pos: exp.pos};
		}
	}

	function parseStatement() {
		return switch stream {
			// if-elseif-else
			case [{tok: Kwd(KwdIf)}, {tok: POpen}]: {
					var cond = getExpr();
					while (true) {
						switch stream {
							case [{tok: Binop(op), pos: p}]: {
									if (op == OpAssign)
										throw "Error at '=': Expect ')' after if condition.";
									switch stream {
										case [{tok: Const(c), pos: p2}]: {
												cond = {expr: EBinop(op, cond, {expr: EConst(c), pos: p2}), pos: p};
											}
										case [{tok: BrOpen, pos: p3}]:
											var map = parseMap(p3);
											var exp = parseExpr(map);
											var pos = p3;
											cond = {expr: EBinop(op, cond, exp), pos: pos};
										case _: throw "Expect ')' at if statement";
									}
								}
							case [{tok: PClose, pos: p}]: break;
							case _: throw "Expect ')' at if statement";
						}
					}

					var body = parseStatement();

					var e2 = switch stream {
						case [{tok: Kwd(KwdElse)}, e2 = parseStatement()]: e2;
						case _: null;
					}
					{expr: EIf(cond, body, e2), pos: body.pos};
				}
			// while loop
			case [{tok: Kwd(KwdWhile), pos: p}, {tok: POpen}]: {
					var cond = getExpr();
					while (true) {
						switch stream {
							case [{tok: Binop(op), pos: p}]: {
									trace(op);
									if (op == OpAssign)
										cond = {expr: EBinop(op, cond, parseRightSideExpr().exp), pos: p};
									switch stream {
										case [{tok: Const(c), pos: p2}]: {
												cond = {expr: EBinop(op, cond, {expr: EConst(c), pos: p2}), pos: p};
											}
										case [{tok: BrOpen, pos: p3}]:
											var map = parseMap(p3);
											var exp = parseExpr(map);
											var pos = p3;
											cond = {expr: EBinop(op, cond, exp), pos: pos};
										case _: throw "Expect ')' at if statement";
									}
								}
							case [{tok: PClose, pos: p}]: break;
							case _: throw "Expect ')' at if statement";
						}
					}

					var body = parseStatement();
					{expr: EWhile(cond, body, true), pos: p};
				}
			case [{tok: Kwd(KwdFor)}, {tok: POpen, pos: p}]: {
					var cond = getExpr();
					while (true) {
						switch stream {
							case [{tok: Binop(OpIn), pos: p}]: {
									while (true) {
										switch stream {
											case [{tok: Const(c), pos: p2}]: cond = {expr: EBinop(OpIn, cond, {expr: EConst(c), pos: p2}), pos: p};
											case [interval = parseInterval()]: {
													cond = {expr: EBinop(OpIn, cond, interval), pos: p};
												}
											case [{tok: BkOpen, pos: p4}]:
												{ // list
													var exps:Array<wrenparse.Data.Expr> = [];
													var pos = null;
													while (true) {
														switch stream {
															case [{tok: BkClose, pos: p5}]: break;
															case [{tok: Comma}]: continue;
															case [{tok: Kwd(KwdNull), pos: p}]:
																exps.push({expr: ENull, pos: p});
																pos = p;
															case [{tok: Const(c), pos: p6}]:
																exps.push(parseExpr({expr: EConst(c), pos: p6}));
																pos = p6;
															case _: {
																	if (peek(0).toString() == "<newline>") {
																		throw "Error at newline: unclosed array;  Expect ']'";
																	}
																}
														}
													}
													var exp = {expr: EArrayDecl(exps), pos: p4};
													pos = p4;
													cond = {expr: EBinop(OpIn, cond, exp), pos: pos};
												}
											case _: break;
										}
									}
									continue;
								}
							case [{tok: PClose, pos: p}]: break;
							case _: throw "Expect ')' at for statement";
						}
					}
					var body = parseStatement();
					{expr: EFor(cond, body), pos: p};
				}
			// block
			case [{tok: BrOpen, pos: p}]: {
					var body = [];
					while (true) {
						var p = parseStatement();
						if (p == null)
							break;
						body.push(p);
					}
					switch stream {
						case [{tok: BrClose, pos: p}]: {expr: EBlock(body), pos: p};
						case _: throw 'unclosed {  at $p';
					}
				}
			case [{tok: Kwd(KwdFalse), pos: p}]: {expr: EConst(CIdent("false")), pos: p};
			case [{tok: Kwd(KwdTrue), pos: p}]: {expr: EConst(CIdent("true")), pos: p};
			// exp
			case [exp = getExpr()]: exp;
			// variable statement: var a = exp
			case [
				{tok: Kwd(KwdVar), pos: p},
				{tok: Const(CIdent(s)), pos: p0},
				{tok: Binop(OpAssign), pos: p1}
			]: {
					var variable = s;
					var exp = null;
					var pos = p;
					var r = parseRightSideExpr();
					pos = r.pos;

					return {
						expr: EVars([
							{
								name: variable,
								expr: r.exp,
								type: null
							}
						]),
						pos: pos
					};
				}
			// range 1..2 or 1...3
			case [interval = parseInterval()]: {
					return interval;
				}
			case [{tok: CommentLine(s)}]: parseStatement(); // ignore comments
			case [{tok: Line}]: parseStatement();
			case [{tok: Kwd(KwdNull), pos: p}]: parseStatement();
			case [{tok: Kwd(KwdBreak), pos: p}]: {expr: EBreak, pos: p};
			case [{tok: Kwd(KwdReturn), pos: p}]: {
					var retVal = null;
					switch stream {
						case [exp = getExpr()]: retVal = exp;
						case _:
					}
					return {expr: EReturn(retVal), pos: p};
				}
			// case [{tok:Kwd(KwdContinue), pos: p}]: {expr: EContinue, pos:p};
			case _: null;
		}
	}

	function parseStatements() {
		var stmts = [];
		while (true) {
			var p = parseStatement();
			if (p == null)
				break;
			stmts.push(p);
		}
		return EStatement(stmts);
	}

	function parseMap(pos) {
		var mapfields:Array<ObjectField> = [];
		while (true) {
			switch stream {
				case [{tok: Line}]:
					continue;
				case [{tok: Comma}]:
					continue;
				case [{tok: BrClose, pos: p}]:
					break;
				case [{tok: Const(CString(c))}, {tok: DblDot, pos: p}]:
					{
						var exp = null;
						var pos = p;
						var r = parseRightSideExpr();
						pos = r.pos;

						if (peek(0).toString() == "<newline>" && mapfields.length != 1) {
							if (peek(1).toString() == ",") {
								throw "Error at ',': Expect '}' after map entries.";
							}
						}

						mapfields.push({
							field: c,
							expr: r.exp
						});
					}
				case _:
					throw 'Expect "}"';
			}
		}
		return {expr: EObjectDecl(mapfields), pos: pos};
	}

	function parseExpr(e:Dynamic) {
		switch (e.expr) {
			case EConst(constant):
				{
					var s = "";
					switch constant {
						case CString(_s) | CIdent(_s) | CInt(_s) | CFloat(_s): s = _s;
						case CRegexp(_, _): unexpected();
					}

					return switch stream {
						// a = exp
						case [{tok: Binop(OpAssign), pos: p1}]: {
								switch constant {
									case CIdent(_):
									case _: throw "Cannot assign value to constant";
								}
								var ident = s;
								var exp = null;
								var pos = p1;
								var r = parseRightSideExpr();
								pos = r.pos;
								return {
									expr: EBinop(OpAssign, e, r.exp),
									pos: r.pos
								};
							}
						case [exprCall = parseExprCall(e)]: exprCall;

						case _: {
								switch peek(0) {
									case {tok: Line}: {
											return e;
										}
									case {tok: Const(c)}: throw 'Expect end of file';
									case _: e;
								}
							}
					}
				}
			case EBinop(op, e1, e2):
				{
					return switch op {
						case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte | OpBoolAnd | OpBoolOr: {
								var exp = e;
								switch op {
									case OpEq | OpNotEq | OpBoolAnd | OpBoolOr: {
											switch stream {
												case [{tok: Const(c), pos: p2}]: {expr: EBinop(op, exp, parseExpr({expr: EConst(c), pos: p2})), pos: e.pos};
												case [{tok: Kwd(KwdTrue), pos: p3}]: exp = {
														expr: EBinop(op, exp, parseExpr({expr: CIdent("true"), pos: p3})),
														pos: e.pos
													};
												case [{tok: Kwd(KwdFalse), pos: p3}]: exp = {
														expr: EBinop(op, exp, parseExpr({expr: CIdent("false"), pos: p3})),
														pos: e.pos
													};
												case _:
											}
										}
									case _:
								}

								return switch stream {
									case [{tok: Question, pos: p}]: {
											var _if = getExpr();
											var _else = null;
											while (true) {
												switch stream {
													case [{tok: DblDot, pos: p}]: {
															var _else = getExpr();
															exp = {expr: ETernary(exp, _if, _else), pos: p};
															break;
														}
													case _: throw "Expect ':' at conditional operator '?'";
												}
											}
											return exp;
										}
									case _: return exp;
								}
							}
						case _: {
								return e;
							}
					}
				}
			case EObjectDecl(o):
				{
					return switch stream {
						case [exprCall = parseExprCall(e)]: exprCall;
						case _: e;
					}
				}
			case EArrayDecl(values):
				{
					return switch stream {
						case [exprCall = parseExprCall(e)]: exprCall;
						case _: e;
					}
				}
			case _:
				return e;
		}
	}

	function parseExprCall(e:Expr) {
		var s = "";
		switch e.expr {
			case EConst(c):
				{
					switch c {
						case CString(_s) | CIdent(_s) | CInt(_s) | CFloat(_s): s = _s;
						case CRegexp(_, _): unexpected();
					}
				}
			case EArrayDecl(_):
				s = "[_]";
			case EObjectDecl(_):
				s = "{_}";
			case _:
		}
		return switch stream {
			// method call
			case [{tok: POpen, pos: pp}]: {
					var args = [];
					while (true) {
						switch stream {
							case [exp = getExpr()]: {
									args.push(exp);
								}
							case [{tok: Kwd(KwdFalse), pos: p}]: args.push(parseExpr({expr: EConst(CIdent("false")), pos: p}));
							case [{tok: Kwd(KwdTrue), pos: p}]: args.push(parseExpr({expr: EConst(CIdent("true")), pos: p}));
							case [{tok: Kwd(KwdNull), pos: p}]: args.push({expr: ENull, pos: p});
							case [{tok: Comma}]: continue;
							case [{tok: PClose}]: break;
							case _: "Expect ')'";
						}
					}
					return {expr: ECall(e, args), pos: pp};
				}
			// Array Access
			case [{tok: BkOpen, pos: pp}]: {
					var acc = null;
					return switch stream {
						case [{tok: Const(c), pos: p}]: {
								acc = parseExpr({expr: EConst(c), pos: p});
								switch stream {
									case [{tok: BkClose, pos: p}]: {}
									case _: throw "Expect ']'";
								}
								return {expr: EArray(e, acc), pos: p};
							}
						case [interval = parseInterval()]: {
								switch stream {
									case [{tok: BkClose, pos: p}]: {}
									case _: throw "Expect ']'";
								}
								return interval;
							}
						case [{tok: BkClose, pos: p}]: {expr: EArray(e, acc), pos: p};
					}
				}
			case [{tok: Dot}]: {
					return switch stream {
						// range a..b
						case [{tok: Dot}]: {
								return switch stream {
									case [{tok: Const(c), pos: p}]: {
											var ret = {expr: EBinop(OpInterval, e, parseExpr({expr: EConst(c), pos: p})), pos: p};
											if (peek(0).toString() == "." && peek(1).toString() == ".") {
												throw "Range does not implement '..(_)'";
											}
											return ret;
										}
									case [{tok: Dot}]: {
											switch stream {
												case [{tok: Const(c), pos: p}]: {
														var ret = {expr: EBinop(OpInterval2, e, parseExpr({expr: EConst(c), pos: p})), pos: p};
														if (peek(0).toString() == "." && peek(1).toString() == ".") {
															throw "Range does not implement '..(_)'";
														}
														return ret;
													}
											}
										}
									case _: throw "Error at range, expect expression";
								}
							}
						// method get a.field
						case [{tok: Const(CIdent(a)), pos: p}]: {
								if (peek(0).toString() != "<newline>") { // a.field()

									// method call
									switch stream {
										case [{tok: POpen, pos: pp}]: {
												var args = [];
												while (true) {
													switch stream {
														case [{tok: Comma}]: {
																switch stream {
																	case [{tok: Line}]: {} // ignore
																	case _:
																}
																continue;
															}
														case [{tok: Line}]: {} // ignore
														case [{tok: Kwd(KwdFalse), pos: p}]: args.push(parseExpr({
																expr: EConst(CIdent("false")),
																pos: p
															}));
														case [{tok: Kwd(KwdTrue), pos: p}]: args.push(parseExpr({
																expr: EConst(CIdent("true")),
																pos: p
															}));
														case [{tok: Kwd(KwdNull), pos: p}]: args.push({expr: ENull, pos: p});
														case [exp = getExpr()]: args.push(getExpr());
														case [{tok: PClose}]: break;
														case _: "Expect ')'";
													}
												}
												return {
													expr: ECall({expr: EField(parseExpr({expr: EConst(CIdent(a)), pos: p}), '$s.$a'), pos: p}, args),
													pos: pp
												};
											}
										// chained get e.boy.call
										case [{tok: Dot}, {tok: Const(CIdent(x)), pos: p2}]:
											{
												var exp = parseExpr({expr: EConst(CIdent(x)), pos: p2});
												return {expr: EField(exp, '$s.$a.$x'), pos: p};
											}
										// method call with block parameter
										case [{tok: BrOpen, pos: pp}]: {
												var args = [];

												switch stream {
													case [{tok: Binop(OpOr)}]: {
															while (true) {
																switch stream {
																	case [{tok: Binop(OpOr)}]: break;
																	case [{tok: Comma}]: continue;
																	case [{tok: Const(c), pos: p3}]: args.push({expr: EConst(c), pos: p3});
																	case _: throw "Expected '|' in block parameter";
																}
															}
														}
													case _:
												}

												var body = parseStatement();

												while (true) {
													switch stream {
														case [{tok: Line}]: continue;
														case [{tok: BrClose, pos: p1}]: break;
														case _: throw "Expected } at block parameter";
													}
												}
												var exp = body != null ? {
													expr: EBlockParam({expr: ECall(e, args), pos: pp}, body),
													pos: body.pos
												} : {expr: ENull, pos: {min: 0, max: 0, file: ""}};
												return {expr: EField(exp, '$s.$a'), pos: pp};
											}
										case _:
									}
								}
								return {expr: EField(parseExpr({expr: EConst(CIdent(a)), pos: p}), '$s.$a'), pos: p};
							}
					}
				}
			case _: {
					if (s != "{_}") {
						switch stream {
							case [binop = makeBinop(e)]: binop;
							case _: e;
						}
					} else {
						return e;
					}
				}
		}
	}

	function makeBinop(e:Expr) {
		return switch stream {
			case [{tok: Binop(OpAdd)}, {tok: Const(c), pos: p2}]: {
					var e1 = e;
					var e2 = parseExpr({expr: EConst(c), pos: p2});
					return {expr: EBinop(OpAdd, e1, e2), pos: p2};
				}
			case [{tok: Binop(OpSub), pos: p}, stmt = parseStatement()]: parseExpr({expr: EBinop(OpSub, e, stmt), pos: p});
			case [{tok: Binop(OpMult), pos: p}, stmt = parseStatement()]: parseExpr({expr: EBinop(OpMult, e, stmt), pos: p});
			case [{tok: Binop(OpDiv), pos: p}, stmt = parseStatement()]: parseExpr({expr: EBinop(OpDiv, e, stmt), pos: p});
			case [{tok: Binop(OpEq), pos: p}, stmt = parseStatement()]: parseExpr({expr: EBinop(OpEq, e, stmt), pos: p});
			case [{tok: Binop(OpNotEq), pos: p}, stmt = parseStatement()]: parseExpr({expr: EBinop(OpNotEq, e, stmt), pos: p});
			case [{tok: Binop(OpGt), pos: p}, stmt = parseStatement()]: {expr: EBinop(OpGt, e, stmt), pos: p};
			case [{tok: Binop(OpGte), pos: p}, stmt = parseStatement()]: {expr: EBinop(OpGte, e, stmt), pos: p};
			case [{tok: Binop(OpLt), pos: p}, stmt = parseStatement()]: {expr: EBinop(OpLt, e, stmt), pos: p};
			case [{tok: Binop(OpLte), pos: p}, stmt = parseStatement()]: {expr: EBinop(OpLte, e, stmt), pos: p};
			case [{tok: Binop(OpBoolAnd), pos: p}, stmt = getExpr()]: parseExpr({expr: EBinop(OpBoolAnd, e, stmt), pos: p});

			case [{tok: Binop(OpBoolOr), pos: p}, stmt = getExpr()]: parseExpr({expr: EBinop(OpBoolOr, e, stmt), pos: p});

			case [{tok: Binop(OpMod), pos: p}, stmt = parseStatement()]: {expr: EBinop(OpMod, e, stmt), pos: p};
		}
	}

	function parseInterval() {
		return switch stream {
			case [{tok: IntInterval(s, isExtra), pos: p}]: {
					return switch stream {
						case [{tok: Const(c), pos: p2}]: {
								var e1 = {expr: EConst(CInt(s)), pos: p};
								var e2 = parseExpr({expr: EConst(c), pos: p2});
								if (!isExtra)
									return {expr: EBinop(OpInterval, e1, e2), pos: p};
								else
									return {expr: EBinop(OpInterval2, e1, e2), pos: p};
							}
						case [{tok: Binop(OpSub), pos: p}, {tok: Const(c), pos: p2}]: {
								var e1 = {expr: EConst(CInt(s)), pos: p};
								var e2 = {expr: EUnop(OpNeg, false, parseExpr({expr: EConst(c), pos: p})), pos: p2};
								if (!isExtra)
									return {expr: EBinop(OpInterval, e1, e2), pos: p};
								else
									return {expr: EBinop(OpInterval2, e1, e2), pos: p};
							}
					}
				}
		}
	}

	function parseRightSideExpr():{exp:wrenparse.Data.Expr, pos:Position} {
		var exp = null;
		var pos = null;

		switch stream {
			case [{tok: Kwd(KwdNull), pos: p}]:
				{
					exp = {expr: ENull, pos: p};
					pos = p;
				}
			case [stmt = getExpr()]:
				{
					exp = stmt;
					pos = stmt.pos;
				}
			case [interval = parseInterval()]:
				{
					exp = interval;
					pos = interval.pos;
				}
			case [{tok: Line}]:
				throw 'Expect expression after "="';
			case _:
				{
					trace(peek(0));
				}
		}

		return {exp: exp, pos: pos};
	}
}

class StringParser extends WrenParser {
	public function new(s:String) {
		var source = byte.ByteData.ofString(s);
		super(source);
	}

	public function exec() {
		var exp = [];
		while (true) {
			switch stream {
				case [{tok: Interpol}]:
					{
						exp.push(getExpr());
					}
				case [{tok: PClose}]:
					break;
			}
		}
		return exp;
	}
}
