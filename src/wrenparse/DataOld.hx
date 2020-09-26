package wrenparse;

import haxe.macro.Expr;


#if (macro && !doc_gen)
@:coreType abstract Position {}
#else

/**
	Represents a position in a file.
**/
typedef Position = {
	/**
		Reference to the filename.
	**/
	var file:String;

	/**
		Position of the first character.
	**/
	var min:Int;

	/**
		Position of the last character.
	**/
	var max:Int;
}
#end

enum Binop {
	/**
		`+`
	**/
	OpAdd;

	/**
		`*`
	**/
	OpMult;

	/**
		`/`
	**/
	OpDiv;

	/**
		`-`
	**/
	OpSub;

	/**
		`=`
	**/
	OpAssign;

	/**
		`==`
	**/
	OpEq;

	/**
		`!=`
	**/
	OpNotEq;

	/**
		`>`
	**/
	OpGt;

	/**
		`>=`
	**/
	OpGte;

	/**
		`<`
	**/
	OpLt;

	/**
		`<=`
	**/
	OpLte;

	/**
		`&`
	**/
	OpAnd;

	/**
		`|`
	**/
	OpOr;

	/**
		`^`
	**/
	OpXor;

	/**
		`&&`
	**/
	OpBoolAnd;

	/**
		`||`
	**/
	OpBoolOr;

	/**
		`<<`
	**/
	OpShl;

	/**
		`>>`
	**/
	OpShr;

	/**
		`>>>`
	**/
	OpUShr;

	/**
		`%`
	**/
	OpMod;

	/**
		`+=` `-=` `/=` `*=` `<<=` `>>=` `>>>=` `|=` `&=` `^=` `%=`
	**/
	OpAssignOp(op:Binop);

	/**
		`..`
	**/
	OpInterval;

	/**
		`...`
	**/
	OpInterval2;

	/**
		`=>`
	**/
	OpArrow;

	/**
		`in`
	**/
	OpIn;

	/**
	 *  `is`
	 */
	OpIs;
}

enum Constant {
	/**
		Represents an integer literal.
	**/
	CInt(v:String);

	/**
		Represents a float literal.
	**/
	CFloat(f:String);

	/**
		Represents a string literal.
	**/
	CString(s:String, ?kind:StringLiteralKind);

	/**
		Represents an identifier.
	**/
	CIdent(s:String);

	/**
		Represents a regular expression literal.

		Example: `~/haxe/i`

		- The first argument `haxe` is a string with regular expression pattern.
		- The second argument `i` is a string with regular expression flags.

		@see https://haxe.org/manual/std-regex.html
	**/
	CRegexp(r:String, opt:String);
}


typedef Expr = {
	/**
		The expression kind.
	**/
	var expr:ExprDef;

	/**
		The position of the expression.
	**/
	var pos:Position;
}

/**
	Represents the kind of a node in the AST.
**/
enum ExprDef {
	/**
		A constant.
	**/
	EConst(c:Constant);

	/**
		Array access `e1[e2]`.
	**/
	EArray(e1:Expr, e2:Expr);

	/**
		Binary operator `e1 op e2`.
	**/
	EBinop(op:Binop, e1:Expr, e2:Expr);

	/**
		Field access on `e.field`.
	**/
	EField(e:Expr, field:String);

	/**
		Parentheses `(e)`.
	**/
	EParenthesis(e:Expr);

	/**
		An object declaration.
	**/
	EObjectDecl(fields:Array<ObjectField>);

	/**
		An array declaration `[el]`.
	**/
	EArrayDecl(values:Array<Expr>);

	/**
		A call `e(params)`.
	**/
	ECall(e:Expr, params:Array<Expr>);

	/**
		A constructor call `new t(params)`.
	**/
	ENew(t:TypePath, params:Array<Expr>);

	/**
		An unary operator `op` on `e`:

		- `e++` (`op = OpIncrement, postFix = true`)
		- `e--` (`op = OpDecrement, postFix = true`)
		- `++e` (`op = OpIncrement, postFix = false`)
		- `--e` (`op = OpDecrement, postFix = false`)
		- `-e` (`op = OpNeg, postFix = false`)
		- `!e` (`op = OpNot, postFix = false`)
		- `~e` (`op = OpNegBits, postFix = false`)
	**/
	EUnop(op:Unop, postFix:Bool, e:Expr);

	/**
		Variable declarations.
	**/
	EVars(vars:Array<Var>);

	/**
		A function declaration.
	**/
	EFunction(kind:Null<FunctionKind>, f:Function);

	/**
		A block of expressions `{exprs}`.
	**/
	EBlock(exprs:Array<Expr>);

	/**
		A `for` expression.
	**/
	EFor(it:Expr, expr:Expr);

	/**
		An `if (econd) eif` or `if (econd) eif else eelse` expression.
	**/
	EIf(econd:Expr, eif:Expr, eelse:Null<Expr>);

	/**
		Represents a `while` expression.

		When `normalWhile` is `true` it is `while (...)`.

		When `normalWhile` is `false` it is `do {...} while (...)`.
	**/
	EWhile(econd:Expr, e:Expr, normalWhile:Bool);

	/**
		Represents a `switch` expression with related cases and an optional.
		`default` case if `edef != null`.
	**/
	ESwitch(e:Expr, cases:Array<Case>, edef:Null<Expr>);

	/**
		Represents a `try`-expression with related catches.
	**/
	ETry(e:Expr, catches:Array<Catch>);

	/**
		A `return` or `return e` expression.
	**/
	EReturn(?e:Null<Expr>);

	/**
		A `break` expression.
	**/
	EBreak;

	/**
		A `continue` expression.
	**/
	EContinue;

	/**
		An `untyped e` source code.
	**/
	EUntyped(e:Expr);

	/**
		A `throw e` expression.
	**/
	EThrow(e:Expr);

	/**
		A `cast e` or `cast (e, m)` expression.
	**/
	ECast(e:Expr, t:Null<ComplexType>);

	/**
		Used internally to provide completion.
	**/
	EDisplay(e:Expr, displayKind:DisplayKind);

	/**
		Used internally to provide completion.
	**/
	EDisplayNew(t:TypePath);

	/**
		A `(econd) ? eif : eelse` expression.
	**/
	ETernary(econd:Expr, eif:Expr, eelse:Expr);

	/**
		A `(e:t)` expression.
	**/
	ECheckType(e:Expr, t:ComplexType);

	/**
		A `@m e` expression.
	**/
	EMeta(s:MetadataEntry, e:Expr);
	ENull;

	EBlockParam(caller:Expr, e:Expr);
}

typedef ObjectField = {
	/**
		The name of the field.
	**/
	var field:String;

	/**
		The field expression.
	**/
	var expr:Expr;

	/**
		How the field name is quoted.
	**/
	var ?quotes:QuoteStatus;
}


typedef Var = {
	/**
		The name of the variable.
	**/
	var name:String;

	/**
		The type-hint of the variable, if available.
	**/
	var type:Null<ComplexType>;

	/**
		The expression of the variable, if available.
	**/
	var expr:Null<Expr>;

	/**
		Whether or not the variable can be assigned to.
	**/
	var ?isFinal:Bool;
}

enum Keyword {
	KwdBreak;
	// KwdContinue;
	KwdClass;
	KwdConstruct;
	KwdElse;
	KwdFalse;
	KwdForeign;
	KwdFor;
	KwdIf;
	KwdImport;
	KwdIn;
	KwdIs;
	KwdReturn;
	KwdStatic;
	KwdSuper;
	KwdThis;
	KwdTrue;
	KwdVar;
	KwdWhile;
	KwdNull;
}

class KeywordPrinter {
	static public function toString(kwd:Keyword) {
		return switch kwd {
			case KwdBreak: "break";
			// case KwdContinue: "continue";
			case KwdClass: "class";
			case KwdConstruct: "construct";
			case KwdElse: "else";
			case KwdFalse: "false";
			case KwdForeign: "foreign";
			case KwdIf: "if";
			case KwdImport: "import";
			case KwdIn: "in";
			case KwdIs: "is";
			case KwdReturn: "return";
			case KwdStatic: "static";
			case KwdSuper: "super";
			case KwdThis: "this";
			case KwdTrue: "true";
			case KwdVar: "var";
			case KwdWhile: "while";
			case KwdNull: "null";
			case KwdFor: "for";
		}
	}
}

enum TokenDef {
	BkOpen;
	BkClose;
	BrOpen;
	BrClose;
	POpen;
	PClose;
	Dot;
	DblDot;
	Comma;
	Question;
	Line;
	Binop(op:wrenparse.Binop);
	Unop(op:haxe.macro.Expr.Unop);
	Comment(s:String);
	CommentLine(s:String);
	IntInterval(s:String, ?extra:Bool);
	Interpol; // string interpolation
	Const(c:Constant);
	Kwd(k:Keyword);
	Error(s:String);
	Eof;
}

class TokenDefPrinter {

	static public function printBinop(op:Binop)
		return switch (op) {
			case OpAdd: "+";
			case OpMult: "*";
			case OpDiv: "/";
			case OpSub: "-";
			case OpAssign: "=";
			case OpEq: "==";
			case OpNotEq: "!=";
			case OpGt: ">";
			case OpGte: ">=";
			case OpLt: "<";
			case OpLte: "<=";
			case OpAnd: "&";
			case OpOr: "|";
			case OpXor: "^";
			case OpBoolAnd: "&&";
			case OpBoolOr: "||";
			case OpShl: "<<";
			case OpShr: ">>";
			case OpUShr: ">>>";
			case OpMod: "%";
			case OpInterval: "..";
			case OpInterval2: "...";
			case OpArrow: "=>";
			case OpIn: "in";
			case OpIs: "is";
			case OpAssignOp(op):
				printBinop(op) + "=";
		}
	static public function toString(def:TokenDef) {
		return switch (def) {
			case BkOpen: "[";
			case BkClose: "]";
			case BrOpen: "{";
			case BrClose: "}";
			case POpen: "(";
			case PClose: ")";
			case Comma: ",";
			case Dot: ".";
			case DblDot: ":";
			case Question: "?";
			case Interpol: '%(';
			case Comment(s): '/*$s*/';
			case CommentLine(s): '//$s';
			case IntInterval(s): '$s...';
			case Binop(op): printBinop(op);
			case Unop(op): new haxe.macro.Printer("").printUnop(op);
			case Kwd(k): k.getName().substr(3).toLowerCase();
			case Const(CInt(s) | CFloat(s) | CIdent(s)): s;
			case Const(CString(s)): '"$s"';
			case Eof: "<eof>";
			case Const(CRegexp(r, opt)): '~/$r/$opt'; // should not be in wren
			case Line: '<newline>';
			case Error(s): 'error: $s';
		}
	}
}

class Token {
	public var tok:TokenDef;
	public var pos:Position;
	public var space = "";

	public function new(tok, pos) {
		this.tok = tok;
		this.pos = pos;
	}

	public function toString() {
		return TokenDefPrinter.toString(tok);
	}
}

typedef ClassField = {
	/**
		The name of the field.
	**/
	var name:String;

	/**
		The documentation of the field, if available. If the field has no
		documentation, the value is `null`.
	**/
	var ?doc:Null<String>;

	/**
		The access modifiers of the field. By default fields have private access.
		@see https://haxe.org/manual/class-field-access-modifier.html
	**/
	var ?access:Array<Access>;

	/**
		The kind of the field.
	**/
	var kind:FieldType;

	/**
		The position of the field.
	**/
	var pos:Position;
}

enum FieldType {
	FGetter(value:CodeDef);
	FSetter(arg:Constant, body:Array<CodeDef>);
	FMethod(?args:Array<Constant>, body:Array<CodeDef>);
	FOperator(op:FieldOp);
}

enum FieldOp {
	FInfixOp(sign:Binop, arg:Constant, body:Array<CodeDef>);
	FPrefixOp(sign:Unop, body:Array<CodeDef>);
	FSubscriptOp(params:Array<Constant>, arg:Constant, body:Array<CodeDef>);
}

enum Access {
	AConstructor;
	AStatic;
	AForeign;
}

class AccessPrinter {
	public static function toString(access:Access){
		return switch access {
			case AConstructor: "construct";
			case AStatic: "static";
			case AForeign: "foreign";
		}
	}
}

enum CodeDef {
	EModule(name:String, t:Array<CodeDef>);
	EClass(d:Definition<ClassFlag, Array<ClassField>>);
	EImport(pack:String, mode:ImportMode);
	EStatement(d:Array<Expr>);
	// EStatic(s:Definition<StaticFlag, FieldType>);
	Eof;
}

enum StatementDef {
	SFunction(name:String, ?args:Array<haxe.macro.Expr.Constant>, body:Array<Dynamic>);
	SExpression(e:ExprDef);
	SIf(exp:Expr, body:Array<StatementDef>);
	SNull;
}

typedef Definition<A, B> = {
	name:String,
	doc:String,
	params:Array<ParamDecl>,
	flags:Array<A>,
	data:B
}

typedef ParamDecl = {
	/**
		The name of the parameter.
	**/
	var name:String;
}

enum ClassFlag {
	HExtends(t:String);
	HForeign;
}

enum ImportMode {
	INormal;
	IWithVars(s:Array<String>);
}

enum StaticFlag {
	SNormal;
	SForeign;
}
