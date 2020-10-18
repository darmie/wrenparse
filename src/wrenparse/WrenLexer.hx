package wrenparse;

import haxe.macro.Expr.Position;
import hxparse.Lexer;
import wrenparse.Data;

enum LexerErrorMsg {
	UnterminatedString;
	UnclosedComment;
	UnterminatedEscapeSequence;
	InvalidEscapeSequence(c:String);
	UnknownEscapeSequence(c:String);
	UnclosedCode;
}

class LexerError {
	public var msg:LexerErrorMsg;
	public var pos:Position;

	public function new(msg, pos) {
		this.msg = msg;
		this.pos = pos;
	}
}

class WrenLexer extends Lexer implements hxparse.RuleBuilder {
	static function mkPos(p:hxparse.Position) {
		return {
			file: p.psource,
			min: p.pmin,
			max: p.pmax
		};
	}

	static function mk(lexer:Lexer, td) {
		return new Token(td, mkPos(lexer.curPos()), WrenLexer.lineCount);
	}

	// @:mapping generates a map with lowercase enum constructor names as keys
	// and the constructor itself as value
	static var keywords = @:mapping(3) Data.Keyword;

	static var buf = new StringBuf();

	static var ident = "_*[a-zA-Z][a-zA-Z0-9_]*|_+|_+[0-9][_a-zA-Z0-9]*";
	static var integer = "([1-9][0-9]*)|0";

	public static var lineCount = 1;


	// @:rule wraps the expression to the right of => with function(lexer) return
	public static var tok = @:rule [
		"" => mk(lexer, Eof),
		"[\r\t ]+" => {
			var space = lexer.current;
			var token:Token = lexer.token(tok);
			token.space = space;
			token;
		},
		"[\n]+" => {
			lineCount++;
			var pos = lexer.curPos();
			var token = mk(lexer, Line);
			token.pos.min = pos.pmin;
			token.pos.max = pos.pmax;
			token;
		},
		"0x[0-9a-fA-F]+" => mk(lexer, Const(CInt(lexer.current))),
		integer => mk(lexer, Const(CInt(lexer.current))),
		integer + "\\.[0-9]+" => mk(lexer, Const(CFloat(lexer.current))),
		// "\\.[0-9]+" => mk(lexer, Const(CFloat(lexer.current))),
		integer + "[eE][\\+\\-]?[0-9]+" => mk(lexer, Const(CFloat(lexer.current))),
		integer + "\\.[0-9]*[eE][\\+\\-]?[0-9]+" => mk(lexer, Const(CFloat(lexer.current))),
		// integer + "\\.\\." => mk(lexer, IntInterval(lexer.current.substr(0, -2), false)),
		// integer + "\\.\\.\\." => mk(lexer, IntInterval(lexer.current.substr(0, -3), true)),
		"//[^\n\r]*" =>{
			lineCount++;
			mk(lexer, CommentLine(lexer.current.substr(2)));
		},
		"~" => mk(lexer, Unop(OpNegBits)),
		"<<" => mk(lexer, Binop(OpShl)),
		">>" => mk(lexer, Binop(OpShl)),
		"&&" => mk(lexer, Binop(OpBoolAnd)),
		"&" => mk(lexer, Binop(OpAnd)),
		"|\\|" => mk(lexer, Binop(OpBoolOr)),
		"|" => mk(lexer, Binop(OpOr)),
		"^" => mk(lexer, Binop(OpXor)),
		"%" => mk(lexer, Binop(OpMod)),
		"+" => mk(lexer, Binop(OpAdd)),
		"*" => mk(lexer, Binop(OpMult)),
		"/" => mk(lexer, Binop(OpDiv)),
		"-" => mk(lexer, Binop(OpSub)),
		"=" => mk(lexer, Binop(OpAssign)),
		"==" => mk(lexer, Binop(OpEq)),
		"!=" => mk(lexer, Binop(OpNotEq)),
		"in" => mk(lexer, Binop(OpIn)),
		"[" => mk(lexer, BkOpen),
		"]" => mk(lexer, BkClose),
		"{" => mk(lexer, BrOpen),
		"}" => mk(lexer, BrClose),
		"\\(" => mk(lexer, POpen),
		"\\)" => mk(lexer, PClose),
		"?" => mk(lexer, Question),
		"!" => mk(lexer, Unop(OpNot)),
		"<" => mk(lexer, Binop(OpLt)),
		">" => mk(lexer, Binop(OpGt)),
		"<=" => mk(lexer, Binop(OpLte)),
		">=" => mk(lexer, Binop(OpGte)),
		":" => mk(lexer, DblDot),
		"\\.\\.\\."=> mk(lexer, Binop(OpInterval2)),
		"\\.\\."=> mk(lexer, Binop(OpInterval)),
		"\\." => mk(lexer, Dot),
		"," => mk(lexer, Comma),
		'"' => {
			buf = new StringBuf();
			var pmin = lexer.curPos();
			var pmax = try lexer.token(string) catch (e:haxe.io.Eof) throw new LexerError(UnterminatedString, mkPos(pmin));
			var token = mk(lexer, Const(CString(unescape(buf.toString(), mkPos(pmin)))));
			token.pos.min = pmin.pmin;
			token;
		},
		'/\\*' => {
			buf = new StringBuf();
			var pmin = lexer.curPos();
			var pmax = try lexer.token(comment) catch (e:haxe.io.Eof) throw new LexerError(UnclosedComment, mkPos(pmin));
			var token = mk(lexer, Comment(buf.toString()));
			token.pos.min = pmin.pmin;
			token;
		},
		"%\\(" => mk(lexer, Interpol),
		ident => {
			var kwd = keywords.get(lexer.current);
			if (kwd != null)
				mk(lexer, Kwd(kwd));
			else
				mk(lexer, Const(CIdent(lexer.current)));
		}
	];

	public static var string = @:rule [
		"\\\\\\\\" => {
			buf.add("\\\\");
			lexer.token(string);
		},
		"\\\\" => {
			buf.add("\\");
			lexer.token(string);
		},
		"\\\\\"" => {
			buf.add('"');
			lexer.token(string);
		},
		'"' => lexer.curPos().pmax,
		"%\\(" => {
			var pmin = lexer.curPos();
			buf.add(lexer.current);
			try {
				lexer.token(codeString);
			} catch (e:haxe.io.Eof)
				throw new LexerError(UnclosedCode, mkPos(pmin));
			lexer.token(string);
		},
		"[^\\\\\"]+" => {
			buf.add(lexer.current);
			lexer.token(string);
		}
	];

	public static var codeString = @:rule [
		"\\(" => {
			buf.add(lexer.current);
			lexer.token(codeString);
		},
		"\\)" => {
			buf.add(lexer.current);
		},
		'"' => {
			buf.addChar('"'.code);
			var pmin = lexer.curPos();
			try
				lexer.token(string)
			catch (e:haxe.io.Eof)
				throw new LexerError(UnterminatedString, mkPos(pmin));
			buf.addChar('"'.code);
			lexer.token(codeString);
		},
		// '/\\*' => {
		// 	var pmin = lexer.curPos();
		// 	try
		// 		lexer.token(comment)
		// 	catch (e:haxe.io.Eof)
		// 		throw new LexerError(UnclosedComment, mkPos(pmin));
		// 	lexer.token(codeString);
		// },
		// "//[^\n\r]*" => {
		// 	buf.add(lexer.current);
		// 	lexer.token(codeString);
		// },
		// "[^/\"'()\n\r]+" => {
		// 	buf.add(lexer.current);
		// 	lexer.token(codeString);
		// },
		"[\r\t ]+" => {
			buf.add(lexer.current);
			lexer.token(codeString);
		},
		"[\n]+" =>{
			lineCount++;
			lexer.token(comment);
		},
	];

	static var commentBuf:StringBuf;
	public static var comment = @:rule [
		"\\*/" => {
			lexer.curPos().pmax;
		},
		'[^/\\*]+[^]' => {
			var content = lexer.current.split("\n");
			for(c in content) lineCount++;
			buf.add(lexer.current);
			lexer.token(comment);
		},
		"*" => {
			buf.add("*");
			lexer.token(comment);
		},
		"[\r\t ]+" => {
			lexer.token(comment);
		},
		"[\n]+" =>{
			lineCount++;
			lexer.token(comment);
		},
		"[^\\*]+" => {
			buf.add(lexer.current);
			lexer.token(comment);
		}
	];



	static inline function unescapePos(pos:Position, index:Int, length:Int) {
		return {
			file: pos.file,
			min: pos.min + index,
			max: pos.min + index + length
		}
	}

	static function unescape(s:String, pos:Position) {
		var b = new StringBuf();
		var i = 0;
		var esc = false;
		while (true) {
			if (s.length == i) {
				break;
			}
			var c = s.charCodeAt(i);
			if (esc) {
				var iNext = i + 1;
				switch (c) {
					case 'n'.code:
						b.add("\n");
					case 'r'.code:
						b.add("\r");
					case 't'.code:
						b.add("\t");
					case '%'.code:
						b.add("/%");
					case '"'.code | '\''.code | '\\'.code:
						b.addChar(c);
					case _ >= '0'.code && _ <= '3'.code => true:
						iNext += 2;
					case 'x'.code:
						var chars = s.substr(i + 1, 2);
						if (!(~/^[0-9a-fA-F]{2}$/.match(chars)))
							throw new LexerError(InvalidEscapeSequence("\\x" + chars), unescapePos(pos, i, 1 + 2));
						var c = Std.parseInt("0x" + chars);
						b.addChar(c);
						iNext += 2;
					case 'u'.code:
						var c:Int;
						var chars = s.substr(i + 1, 4);
						if (!(~/^[0-9a-fA-F]{4}$/.match(chars)))
							throw new LexerError(InvalidEscapeSequence("\\u" + chars), unescapePos(pos, i, 1 + 4));
						c = Std.parseInt("0x" + chars);
						iNext += 4;

						b.addChar(c);
					case 'U'.code:
						var c:Int;

						var chars = s.substr(i + 1, 4);
						if (!(~/^[0-9a-fA-F]{4}$/.match(chars)))
							throw new LexerError(InvalidEscapeSequence("\\u" + chars), unescapePos(pos, i, 1 + 4));
						c = Std.parseInt("0x" + chars);
						iNext += 8;
						b.addChar(c);
					case c:
						throw new LexerError(UnknownEscapeSequence("\\" + String.fromCharCode(c)), unescapePos(pos, i, 1));
				}
				esc = false;
				i = iNext;
			} else
				switch (c) {
					case '\\'.code:
						++i;
						esc = true;
					case _:
						b.addChar(c);
						++i;
				}
		}
		return b.toString();
	}
}
