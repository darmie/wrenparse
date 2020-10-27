package wrenparse;

import haxe.Constraints.Function;
import wrenparse.objects.*;
import wrenparse.IO;

enum TokenType  {
    TOKEN_LEFT_PAREN;
    TOKEN_RIGHT_PAREN;
    TOKEN_LEFT_BRACKET;
    TOKEN_RIGHT_BRACKET;
    TOKEN_LEFT_BRACE;
    TOKEN_RIGHT_BRACE;
    TOKEN_COLON;
    TOKEN_DOT;
    TOKEN_DOTDOT;
    TOKEN_DOTDOTDOT;
    TOKEN_COMMA;
    TOKEN_STAR;
    TOKEN_SLASH;
    TOKEN_PERCENT;
    TOKEN_PLUS;
    TOKEN_MINUS;
    TOKEN_LTLT;
    TOKEN_GTGT;
    TOKEN_PIPE;
    TOKEN_PIPEPIPE;
    TOKEN_CARET;
    TOKEN_AMP;
    TOKEN_AMPAMP;
    TOKEN_BANG;
    TOKEN_TILDE;
    TOKEN_QUESTION;
    TOKEN_EQ;
    TOKEN_LT;
    TOKEN_GT;
    TOKEN_LTEQ;
    TOKEN_GTEQ;
    TOKEN_EQEQ;
    TOKEN_BANGEQ;
  
    TOKEN_BREAK;
    TOKEN_CLASS;
    TOKEN_CONSTRUCT;
    TOKEN_ELSE;
    TOKEN_FALSE;
    TOKEN_FOR;
    TOKEN_FOREIGN;
    TOKEN_IF;
    TOKEN_IMPORT;
    TOKEN_IN;
    TOKEN_IS;
    TOKEN_NULL;
    TOKEN_RETURN;
    TOKEN_STATIC;
    TOKEN_SUPER;
    TOKEN_THIS;
    TOKEN_TRUE;
    TOKEN_VAR;
    TOKEN_WHILE;
  
    TOKEN_FIELD;
    TOKEN_STATIC_FIELD;
    TOKEN_NAME;
    TOKEN_NUMBER;
    
    // A string literal without any interpolation or the last section of a
    // string following the last interpolated expression.
    TOKEN_STRING;
    
    // A portion of a string literal preceding an interpolated expression. This
    // string:
    //
    //     "a %(b) c %(d) e"
    //
    // is tokenized to:
    //
    //     TOKEN_INTERPOLATION "a "
    //     TOKEN_NAME          b
    //     TOKEN_INTERPOLATION " c "
    //     TOKEN_NAME          d
    //     TOKEN_STRING        " e"
    TOKEN_INTERPOLATION;
  
    TOKEN_LINE;
  
    TOKEN_ERROR;
    TOKEN_EOF;
}

class Token {
    public var type:TokenType;
    /**
     * The beginning of the token; pointing directly into the source.
     */
    public var start:String;
    /**
     * The length of the token in characters.
     *
     */
    public var length:Int;
    /**
     * The 1-based line where the token appears.
     */
    public var line:Int;

    /**
     * The parsed value if the token is a literal.
     */
    public var value:Value;

    public function new(){}
}


typedef Keyword = {
    identifier:String,
    length:Int,
    tokenType:TokenType
}

@:arrayAccess
abstract Keywords(Array<Keyword>) from Array<Keyword> to Array<Keyword> {
    public inline function new(){
        this = [
            {identifier:"break",     length:5, tokenType:TOKEN_BREAK},
            {identifier:"class",     length:5, tokenType:TOKEN_CLASS},
            {identifier:"construct", length:9, tokenType:TOKEN_CONSTRUCT},
            {identifier:"else",      length:4, tokenType:TOKEN_ELSE},
            {identifier:"false",     length:5, tokenType:TOKEN_FALSE},
            {identifier:"for",       length:3, tokenType:TOKEN_FOR},
            {identifier:"foreign",   length:7, tokenType:TOKEN_FOREIGN},
            {identifier:"if",        length:2, tokenType:TOKEN_IF},
            {identifier:"import",    length:6, tokenType:TOKEN_IMPORT},
            {identifier:"in",        length:2, tokenType:TOKEN_IN},
            {identifier:"is",        length:2, tokenType:TOKEN_IS},
            {identifier:"null",      length:4, tokenType:TOKEN_NULL},
            {identifier:"return",    length:6, tokenType:TOKEN_RETURN},
            {identifier:"static",    length:6, tokenType:TOKEN_STATIC},
            {identifier:"super",     length:5, tokenType:TOKEN_SUPER},
            {identifier:"this",      length:4, tokenType:TOKEN_THIS},
            {identifier:"true",      length:4, tokenType:TOKEN_TRUE},
            {identifier:"var",       length:3, tokenType:TOKEN_VAR},
            {identifier:"while",     length:5, tokenType:TOKEN_WHILE},
            {identifier:null,        length:0, tokenType:TOKEN_EOF} // Sentinel to mark the end of the array.           
        ];
    }

    @:arrayAccess
    public inline function get(i:Int):Keyword{
        return this[i];
    }
}

typedef Local = {
	// The name of the local variable. This points directly into the original
	// source code string.
	?name:String,
	// The length of the local variable's name.
	?length:Int,
	// The depth in the scope chain that this variable was declared at. Zero is
	// the outermost scope--parameters for a method, or the first local block in
	// top level code. One is the scope within that, etc.
	?depth:Int,
	// If this local variable is being used as an upvalue.
	?isUpvalue:Bool
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
	?start:Int,
	// Index of the argument for the CODE_JUMP_IF instruction used to exit the
	// loop. Stored so we can patch it once we know where the loop ends.
	?exitJump:Int,
	// Index of the first instruction of the body of the loop.
	?body:Int,
	// Depth of the scope(s) that need to be exited if a break is hit inside the
	// loop.
	?scopeDepth:Int,
	// The loop enclosing this one, or NULL if this is the outermost loop.
	?enclosing:Null<Loop>,
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

typedef TSignature = {
	?type:SignatureType,
	?length:Int,
	?name:String,
	?arity:Int
}

@:forward(type, length, name, arity)
abstract Signature(TSignature) from TSignature to TSignature {
	inline function new(sig:TSignature) {
		this = sig;
	}

	function parameterList(numParams:Int, leftBracket:String, rightBracket:String):String {
		var i = 0;
		var ref = leftBracket;
		while (i < numParams && i < Compiler.MAX_PARAMETERS) {
			if (i > 0)
				ref += ",";
			ref += "_";
			i++;
		}
		ref += rightBracket;
		return ref;
	}

	public inline function toString():String {
		var name = this.name;
		switch this.type {
			case SIG_METHOD:
				name += parameterList(this.arity, "(", ")");
			case SIG_GETTER:
				{}
			case SIG_SETTER:
				{
					name += "=";
					name += parameterList(this.arity, "(", ")");
				}
			case SIG_SUBSCRIPT:
				name = "";
				name += parameterList(this.arity, "[", "]");
			case SIG_SUBSCRIPT_SETTER:
				{
					name += parameterList(this.arity - 1, "[", "]");
					name += "=";
					name += parameterList(this.arity, "(", ")");
				}
			case SIG_INITIALIZER:
				{
					name = 'init $name';
					name += parameterList(this.arity, "(", ")");
				}
		}
		name += String.fromCharCode(0);
		return name;
	}
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



typedef GrammarFn = (compiler:Compiler, canAssign:Bool) -> Void;
typedef SignatureFn = (compiler:Compiler, signature:Signature) -> Void;

enum abstract Precedence(Int) from Int to Int {
	var PREC_NONE = 0;
	var PREC_LOWEST;
	var PREC_ASSIGNMENT; // =
	var PREC_CONDITIONAL; // ?:
	var PREC_LOGICAL_OR; // ||
	var PREC_LOGICAL_AND; // &&
	var PREC_EQUALITY; // == !=
	var PREC_IS; // is
	var PREC_COMPARISON; // < > <= >=
	var PREC_BITWISE_OR; // |
	var PREC_BITWISE_XOR; // ^
	var PREC_BITWISE_AND; // &
	var PREC_BITWISE_SHIFT; // << >>
	var PREC_RANGE; // .. ...
	var PREC_TERM; // + -
	var PREC_FACTOR; // * / %
	var PREC_UNARY; // unary - ! ~
	var PREC_CALL; // . () []
	var PREC_PRIMARY;
}

typedef GrammarRule = {
	?prefix:GrammarFn,
	?infix:GrammarFn,
	?method:SignatureFn,
	?precedence:Precedence,
	?name:String
};

@:arrayAccess
abstract GrammarRules(Map<TokenType, GrammarRule>) from Map<TokenType, GrammarRule> to Map<TokenType, GrammarRule> {
    public inline function UNUSED():GrammarRule {
        return {precedence:PREC_NONE}
    }

    public inline function PREFIX(fn:GrammarFn):GrammarRule {
        return {
            prefix:fn,
            precedence:PREC_NONE
        }
    }

    public inline function INFIX(prec:Precedence, fn:GrammarFn):GrammarRule {
        return {
            infix:fn,
            precedence:prec
        }
    }

    public inline function INFIX_OPERATOR(prec:Precedence, name:String):GrammarRule {
        return {
            name:name,
            infix: Grammar.infixOp,
            method: Grammar.infixSignature,
            precedence:prec
        };
    }

    public inline function PREFIX_OPERATOR(name:String):GrammarRule {
        return { prefix:Grammar.unaryOp, method:Grammar.unarySignature, precedence:PREC_NONE, name:name};
    }

    public inline function OPERATOR(name:String):GrammarRule {
        return { prefix:Grammar.unaryOp, infix:Grammar.infixOp, method:Grammar.mixedSignature, precedence:PREC_TERM, name:name}
    }



    public inline function new(){
        this = [
            TOKEN_LEFT_PAREN => PREFIX(Grammar.grouping),
            TOKEN_RIGHT_PAREN  => UNUSED(),
            TOKEN_LEFT_BRACKET => { prefix:Grammar.list, infix:Grammar.subscript, method:Grammar.subscriptSignature, precedence:PREC_CALL},
            TOKEN_RIGHT_BRACKET => UNUSED(),
            TOKEN_LEFT_BRACE    => PREFIX(Grammar.map),
            TOKEN_RIGHT_BRACE   => UNUSED(),
            TOKEN_COLON         => UNUSED(),
            TOKEN_DOT           => INFIX(PREC_CALL, Grammar.call),
            TOKEN_DOTDOT        => INFIX_OPERATOR(PREC_RANGE, ".."),
            TOKEN_DOTDOTDOT     => INFIX_OPERATOR(PREC_RANGE, "..."),
            TOKEN_COMMA         => UNUSED(),
            TOKEN_STAR          => INFIX_OPERATOR(PREC_FACTOR, "*"),
            TOKEN_SLASH         => INFIX_OPERATOR(PREC_FACTOR, "/"),
            TOKEN_PERCENT       => INFIX_OPERATOR(PREC_FACTOR, "%"),
            TOKEN_PLUS          => INFIX_OPERATOR(PREC_TERM, "+"),
            TOKEN_MINUS         => OPERATOR("-"),
            TOKEN_LTLT          => INFIX_OPERATOR(PREC_BITWISE_SHIFT, "<<"),
            TOKEN_GTGT          => INFIX_OPERATOR(PREC_BITWISE_SHIFT, ">>"),
            TOKEN_PIPE          => INFIX_OPERATOR(PREC_BITWISE_OR, "|"),
            TOKEN_PIPEPIPE      => INFIX(PREC_LOGICAL_OR, Grammar.or_),
            TOKEN_CARET         => INFIX_OPERATOR(PREC_BITWISE_XOR, "^"),
            TOKEN_AMP           => INFIX_OPERATOR(PREC_BITWISE_AND, "&"),
            TOKEN_AMPAMP        => INFIX(PREC_LOGICAL_AND, Grammar.and_),
            TOKEN_BANG          => PREFIX_OPERATOR("!"),
            TOKEN_TILDE         => PREFIX_OPERATOR("~"),
            TOKEN_QUESTION      => INFIX(PREC_ASSIGNMENT, Grammar.conditional),
            TOKEN_EQ            => UNUSED(),
            TOKEN_LT            => INFIX_OPERATOR(PREC_COMPARISON, "<"),
            TOKEN_GT            => INFIX_OPERATOR(PREC_COMPARISON, ">"),
            TOKEN_LTEQ          => INFIX_OPERATOR(PREC_COMPARISON, "<="),
            TOKEN_GTEQ          => INFIX_OPERATOR(PREC_COMPARISON, ">="),
            TOKEN_EQEQ          => INFIX_OPERATOR(PREC_EQUALITY, "=="),
            TOKEN_BANGEQ        => INFIX_OPERATOR(PREC_EQUALITY, "!="),
            TOKEN_BREAK         => UNUSED(),
            TOKEN_CLASS         => UNUSED(),
            TOKEN_CONSTRUCT     => { method:Grammar.constructorSignature, precedence:PREC_NONE },
            TOKEN_ELSE          => UNUSED(),
            TOKEN_FALSE         => PREFIX(Grammar.boolean),
            TOKEN_FOR           => UNUSED(),
            TOKEN_FOREIGN       => UNUSED(),
            TOKEN_IF            => UNUSED(),
            TOKEN_IMPORT        => UNUSED(),
            TOKEN_IN            => UNUSED(),
            TOKEN_IS            => INFIX_OPERATOR(PREC_IS, "is"),
            TOKEN_NULL          => PREFIX(Grammar.null_),
            TOKEN_RETURN        => UNUSED(),
            TOKEN_STATIC        => UNUSED(),
            TOKEN_SUPER         => PREFIX(Grammar.super_),
            TOKEN_THIS          => PREFIX(Grammar.this_),
            TOKEN_TRUE          => PREFIX(Grammar.boolean),
            TOKEN_VAR           => UNUSED(),
            TOKEN_WHILE         => UNUSED(),
            TOKEN_FIELD         => PREFIX(Grammar.field),
            TOKEN_STATIC_FIELD  => PREFIX(Grammar.staticField),
            TOKEN_NAME          => { prefix:Grammar.name, method:Grammar.namedSignature, precedence:PREC_NONE},
            TOKEN_NUMBER        => PREFIX(Grammar.literal),
            TOKEN_STRING        => PREFIX(Grammar.literal),
            TOKEN_INTERPOLATION => PREFIX(Grammar.stringInterpolation),
            TOKEN_LINE          => UNUSED(),
            TOKEN_ERROR         => UNUSED(),
            TOKEN_EOF           => UNUSED()
        ];
    }


    @:arrayAccess
    public inline function get(tokenType:TokenType){
        return this.get(tokenType);
    }
}