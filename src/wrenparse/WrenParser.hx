package wrenparse;

import haxe.io.UInt8Array;
import haxe.io.BytesData;
import haxe.io.BytesBuffer;
import polygonal.ds.tools.mem.ByteMemory;
import wrenparse.objects.ObjString;
import haxe.io.BytesOutput;
import haxe.io.Bytes;
import wrenparse.IO.ByteBuffer;
import haxe.io.Eof;
import wrenparse.objects.ObjModule;
import wrenparse.Data;

using StringTools;


@:allow(wrenparse.Compiler)
@:allow(wrenparse.Grammar)
class WrenParser {
	public var vm:VM;
	public var source:String;
	public var moduleName:String;

	public var hasError:Bool;

	/**
	 * Whether compile errors should be printed to stderr or discarded.
	 */
	public var printErrors:Bool;

	/**
	 * If subsequent newline tokens should be discarded.
	 */
	public var skipNewLines:Bool;

	public var module:ObjModule;

	public var currentLine:Int;

	/**
	 * The most recently consumed/advanced token.
	 */
	public var previous:Token;

	/**
	 * The most recently lexed token.
	 */
	public var current:Token;

	/**
	 * The beginning of the currently-being-lexed token in [source].
	 */
	public var tokenStart:String;

	/**
	 * The current character being lexed in [source].
	 */
	public var currentChar:String;

	var currentOffset:Int = 0;
	var tokenOffset:Int = 0;

	/**
	 * Tracks the lexing state when tokenizing interpolated strings.
	 *
	 * Interpolated strings make the lexer not strictly regular: we don't know
	 * whether a ")" should be treated as a RIGHT_PAREN token or as ending an
	 * interpolated expression unless we know whether we are inside a string
	 * interpolation and how many unmatched "(" there are. This is particularly
	 * complex because interpolation can nest:
	 *
	 *      " %( " %( inner ) " ) "
	 *
	 * This tracks that state. The parser maintains a stack of ints, one for each
	 * level of current interpolation nesting. Each value is the number of
	 * unmatched "(" that are waiting to be closed.
	 */
	public var parens:Array<Int>;

	public var numParens:Int;

	final keywords:Keywords = new Keywords();

	public function new(source:byte.ByteData = null, moduleName:String = "main") {
		this.moduleName = moduleName;
		this.current = new Token();
		this.parens = [];
	}

	public function printError(line:Int, label:String, message:String) {
		this.hasError = true;
		if (!this.printErrors)
			return;

		// Only report errors if there is a WrenErrorFn to handle them.
		if (this.vm.config.errorFn == null)
			return;
		var messageBuf = new StringBuf();
		messageBuf.add('$label:');
		messageBuf.add(message);

		var module = this.module.name;
		var module_name = module != null ? module.value.join("") : "<unknown>";
		this.vm.config.errorFn(this.vm, WREN_ERROR_COMPILE, module_name, line, message);
	}

	inline function lexError(message:String) {
		printError(this.currentLine, "Error", message);
	}

	/**
	 * Returns true if [c] is a valid (non-initial) identifier character.
	 * @param name
	 */
	inline function isName(c:String) {
		return return (c.charCodeAt(0) >= 'a'.charCodeAt(0) && c.charCodeAt(0) <= 'z'.charCodeAt(0))
			|| (c.charCodeAt(0) >= 'A'.charCodeAt(0) && c.charCodeAt(0) <= 'Z'.charCodeAt(0))
			|| c.charCodeAt(0) == '_'.charCodeAt(0);
	}

	/**
	 * Returns true if [c] is a digit.
	 * @param c
	 */
	inline function isDigit(c:String) {
		return c.charCodeAt(0) >= '0'.charCodeAt(0) && c.charCodeAt(0) <= '9'.charCodeAt(0);
	}

	/**
	 * Returns the current character the parser is sitting on.
	 */
	inline function peekChar() {
		return this.source.charAt(currentOffset);
	}

	/**
	 * Returns the character after the current character.
	 */
	inline function peekNextChar() {
		// If we're at the end of the source, don't read past it.
		if (peekChar().charCodeAt(0) == 0x05)
            return String.fromCharCode(0x05);
		return this.source.charAt(currentOffset + 1);
	}

	/**
	 * Advances the parser forward one character.
	 */
	inline function nextChar() {
        var c = peekChar();
        currentOffset++;
		if (c == '\n')
            this.currentLine++;
		return c;
	}

	/**
	 * If the current character is [c], consumes it and returns `true`.
	 * @param c
	 * @return Bool
	 */
	inline function matchChar(c:String):Bool {
		if (peekChar() != c)
			return false;
        nextChar();
		return true;
	}

	/**
	 * Sets the parser's current token to the given [type] and current character
	 * range.
	 * @param type
	 */
	inline function makeToken(type:TokenType) {
        this.current = new Token();
		this.current.type = type;
		// trace(this.current.type);
		this.current.start = this.tokenStart.substring(this.tokenOffset, this.currentOffset);
		this.current.length = this.tokenStart.length;
        this.current.line = this.currentLine;
		// Make line tokens appear on the line containing the "\n".
		if (type == TOKEN_LINE){
            this.current.line--;
		}
	}

	/**
	 * If the current character is [c], then consumes it and makes a token of type
	 * [two]. Otherwise makes a token of type [one].
	 * @param c
	 * @param two
	 * @param one
	 */
	inline function twoCharToken(c:String, two:TokenType, one:TokenType) {
		makeToken(matchChar(c) ? two : one);
	}

	/**
	 * Skips the rest of the current line.
	 */
	inline function skipLineComment() {
		while (peekChar() != '\n' && peekChar() != String.fromCharCode(0x05)) {
			nextChar();
		}
	}

	/**
	 * Skips the rest of a block comment.
	 */
	function skipBlockComment() {
		var nesting = 1;
		while (nesting > 0) {
			if (peekChar() == String.fromCharCode(0x05)) {
				lexError("Unterminated block comment.");
				return;
			}

			if (peekChar() == '/' && peekNextChar() == '*') {
				nextChar();
				nextChar();
				nesting++;
				continue;
			}

			if (peekChar() == '*' && peekNextChar() == '/') {
				nextChar();
				nextChar();
				nesting--;
				continue;
			}

			// Regular comment character.
			nextChar();
		}
	}

	/**
	 * Reads the next character, which should be a hex digit (0-9, a-f, or A-F) and
	 * returns its numeric value. If the character isn't a hex digit, returns -1.
	 * @return Int
	 */
	inline function readHexDigit():Int {
		var c = nextChar().charCodeAt(0);
		if (c >= '0'.charCodeAt(0) && c <= '9'.charCodeAt(0))
			return c - '0'.charCodeAt(0);
		if (c >= 'a'.charCodeAt(0) && c <= 'f'.charCodeAt(0))
			return c - 'a'.charCodeAt(0) + 10;
		if (c >= 'A'.charCodeAt(0) && c <= 'F'.charCodeAt(0))
			return c - 'A'.charCodeAt(0) + 10;

		// Don't consume it if it isn't expected. Keeps us from reading past the end
		// of an unterminated string.

		this.currentChar = this.source.charAt(this.currentOffset--);

		return -1;
	}

	/**
	 * Finishes lexing a hexadecimal number literal.
	 */
	inline function readHexNumber() {
		// Skip past the `x` used to denote a hexadecimal literal.
		nextChar();
		// Iterate over all the valid hexadecimal digits found.
		while (readHexDigit() != -1)
			continue;
		makeNumber();
	}

	function makeNumber() {
		try {
            this.current.value = Value.NUM_VAL(Std.parseFloat(this.tokenStart.substring(this.tokenOffset, this.currentOffset)));
		} catch (e:haxe.Exception) {
			lexError('${e.message}');
			this.current.value = Value.NUM_VAL(0);
		}

		makeToken(TOKEN_NUMBER);
	}

	function readNumber() {
		while (isDigit(peekChar())){
            nextChar();
        }

		// See if it has a floating point. Make sure there is a digit after the "."
		// so we don't get confused by method calls on number literals.
		if (peekChar() == '.' && isDigit(peekNextChar())) {
			nextChar();
			while (isDigit(peekChar()))
				nextChar();
		}

		// See if the number is in scientific notation.
		if (matchChar('e') || matchChar('E')) {
			// Allow a single positive/negative exponent symbol.
			if (!matchChar('+')) {
				matchChar('-');
			}

			if (!isDigit(peekChar())) {
				lexError("Unterminated scientific notation.");
			}

			while (isDigit(peekChar()))
				nextChar();
		}
		makeNumber();
	}

	/**
	 * Finishes lexing an identifier. Handles reserved words.
	 * @param type
	 */
	inline function readName(type:TokenType) {
		while (isName(peekChar()) || isDigit(peekChar())) {
			nextChar();
		}
		var i = 0;
		while (keywords[i].identifier != null) {
            var kwd:Keyword = keywords[i];
            
            var word = this.tokenStart.substring(this.tokenOffset, this.currentOffset);
            
			if (word == kwd.identifier) {
                type = keywords[i].tokenType;
                // trace(word, type);
				break;
			}
			i++;
        }
		makeToken(type);
	}

	/**
	 * Reads [digits] hex digits in a string literal and returns their number value.
	 * @param digits
	 * @param description
	 */
	inline function readHexEscape(digits:Int, description:String) {
		var value = 0;
		for (i in 0...digits) {
			if (peekChar() == '"' || peekChar() == String.fromCharCode(0x05)) {
				lexError('Incomplete $description escape sequence.');

				// Don't consume it if it isn't expected. Keeps us from reading past the
				// end of an unterminated string.
                this.currentChar = this.source.charAt(this.currentOffset--);
                
				break;
			}

			var digit = readHexDigit();
			if (digit == -1) {
				lexError('Invalid $description escape sequence.');
				break;
			}

			value = (value * 16) | digit;
		}

		return value;
	}

	inline function readUnicodeEscape(string:ByteBuffer, length:Int) {
		var value = readHexEscape(length, "Unicode");
		// Grow the buffer enough for the encoded result.
		var numBytes = Utils.utf8EncodeNumBytes(value);
		if (numBytes != 0) {
			string.fill(0, numBytes);
			// var b = ByteMemory.toArray(string.data, numBytes, string.count);
			Utils.utf8Encode(value, string);
			// for(i in 0...string.count){
			// 	string.write(b[i]);
			// }
		}
	}

	/**
	 * Finishes lexing a string literal.
	 */
	function readString() {
		var string = new ByteBuffer(this.vm);
		var type = TOKEN_STRING;

		while (true) {
			var c = nextChar();
			var eof = String.fromCharCode(0x05);
			if (c == '"')
				break;
			if (c == eof) {
				lexError("Unterminated string.");

				// Don't consume it if it isn't expected. Keeps us from reading past the
				// end of an unterminated string.
                this.currentOffset--;
				break;
			}
			if (c == "%") {
				if (this.numParens < Compiler.MAX_INTERPOLATION_NESTING) {
					// TODO: Allow format string.
					if (nextChar() != '(')
						lexError("Expect '(' after '%'.");
					this.parens[this.numParens++] = 1;
					type = TOKEN_INTERPOLATION;
					break;
				}

				lexError('Interpolation may only nest ${Compiler.MAX_INTERPOLATION_NESTING} levels deep.');
			}
			
			if (c == "\\") {
				switch (nextChar()) {
					case '"':
						string.write('"'.charCodeAt(0));
					case '\\':
						string.write('\\'.charCodeAt(0));
					case "%":
						string.write('%'.charCodeAt(0));
					case '0':
						string.write(eof.charCodeAt(0));
					case 'a':
						string.write(0x07);
					case 'b':
						string.write(0x08);
					case 'f':
						string.write(0x0C);
					case 'n':
						string.write('\n'.charCodeAt(0));
					case 'r':
						string.write('\r'.charCodeAt(0));
					case 't':
						string.write('\t'.charCodeAt(0));
					case 'u':
						readUnicodeEscape(string, 4);
					case 'U':
						readUnicodeEscape(string, 8);
					case 'v':
						string.write(0x0B);
					case 'x':
						{
							string.write(readHexEscape(2, "byte"));
						}
					case _:
						{
							lexError('Invalid escape character \'${String.fromCharCode(this.currentOffset - 1)}\'.');
						}
				}
			} else {
				if(this.current.start == "(" || this.current.start == ")"){
					continue;
				}
				string.write(c.charCodeAt(0));
			}
		}
		var s = UInt8Array.fromBytes(string.data).getData().bytes.toString();
		this.current.value = ObjString.newString(vm, s);
		string.clear();
		makeToken(type);
	}

	/**
	 * Lex the next token and store it in [parser.current].
	 */
	public function nextToken() {
		this.previous = this.current;
		// If we are out of tokens, don't try to tokenize any more. We *do* still
		// copy the TOKEN_EOF to previous so that code that expects it to be consumed
		// will still work.
		if (this.current.type == TOKEN_EOF)
			return;
		var eof = "";
		while (peekChar() != eof) {
            this.tokenOffset = this.currentOffset;
			var c = nextChar();
			switch c {
				case '(':
					{
						// If we are inside an interpolated expression, count the unmatched "(".
						if (this.numParens > 0)
                            this.parens[this.numParens - 1]++;
                        makeToken(TOKEN_LEFT_PAREN);
						return;
					}
				case ')':
					{
						// If we are inside an interpolated expression, count the ")".
						if (this.numParens > 0 && --this.parens[this.numParens - 1] == 0) {
							// This is the final ")", so the interpolation expression has ended.
							// This ")" now begins the next section of the template string.
							this.numParens--;
							readString();
							return;
                        }
						makeToken(TOKEN_RIGHT_PAREN);
						return;
					}
				case '[':
					makeToken(TOKEN_LEFT_BRACKET);
					return;
				case ']':
					makeToken(TOKEN_RIGHT_BRACKET);
					return;
				case '{':
					makeToken(TOKEN_LEFT_BRACE);
					return;
				case '}':
					makeToken(TOKEN_RIGHT_BRACE);
					return;
				case ':':
					makeToken(TOKEN_COLON);
					return;
				case ',':
					makeToken(TOKEN_COMMA);
					return;
				case '*':
					makeToken(TOKEN_STAR);
					return;
				case '%':
					makeToken(TOKEN_PERCENT);
					return;
				case '^':
					makeToken(TOKEN_CARET);
					return;
				case '+':
					makeToken(TOKEN_PLUS);
					return;
				case '-':
					makeToken(TOKEN_MINUS);
					return;
				case '~':
					makeToken(TOKEN_TILDE);
					return;
				case '?':
					makeToken(TOKEN_QUESTION);
					return;
				case '|':
					twoCharToken('|', TOKEN_PIPEPIPE, TOKEN_PIPE);
					return;
				case '&':
					twoCharToken('&', TOKEN_AMPAMP, TOKEN_AMP);
					return;
				case '=':
					twoCharToken('=', TOKEN_EQEQ, TOKEN_EQ);
					return;
				case '!':
					twoCharToken('=', TOKEN_BANGEQ, TOKEN_BANG);
					return;
				case '.':
					if (matchChar('.')) {
						twoCharToken('.', TOKEN_DOTDOTDOT, TOKEN_DOTDOT);
						return;
					}

					makeToken(TOKEN_DOT);
					return;
				case '/':
					{
						if (matchChar('/')) {
							skipLineComment();
							continue;
						}

						if (matchChar('*')) {
							skipBlockComment();
							continue;
						}

						makeToken(TOKEN_SLASH);
						return;
					}
				case '<':
					{
						if (matchChar('<')) {
							makeToken(TOKEN_LTLT);
						} else {
							twoCharToken('=', TOKEN_LTEQ, TOKEN_LT);
						}
						return;
					}
				case '>':
					{
						if (matchChar('>')) {
							makeToken(TOKEN_GTGT);
						} else {
							twoCharToken('=', TOKEN_GTEQ, TOKEN_GT);
						}
						return;
					}
				case '\n':
					makeToken(TOKEN_LINE);
					return;
				case ' ' | '\r' | '\t':
					{
						// Skip forward until we run out of whitespace.
						while (peekChar() == ' ' || peekChar() == '\r' || peekChar() == '\t') {
                           nextChar();
                        }
					}
				case '"':
					readString();
					return;
				case '_':
					readName(peekChar() == '_' ? TOKEN_STATIC_FIELD : TOKEN_FIELD);
					return;
				case '0':
					if (peekChar() == 'x') {
						readHexNumber();
						return;
                    }
					readNumber();
					return;
				case _:
					{
						if (this.currentLine == 1 && c == '#' && peekChar() == '!') {
							// Ignore shebang on the first line.
							skipLineComment();
							continue;
						}
						if (isName(c)) {
							readName(TOKEN_NAME);
						} else if (isDigit(c)) {
							readNumber();
						} else {
							if (c.charCodeAt(0) >= 32 && c.charCodeAt(0) <= 126) {
								lexError('Invalid character \'$c\'.');
							} else {
								// Don't show non-ASCII values since we didn't UTF-8 decode the
								// bytes. Since there are no non-ASCII byte values that are
								// meaningful code units in Wren, the lexer works on raw bytes,
								// even though the source code and console output are UTF-8.
								trace(String.fromCharCode(0x07) == c);
								var buf = Bytes.ofString(c);
								
								lexError('Invalid byte 0x${buf.toHex()}.');
							}
							this.current.type = TOKEN_ERROR;
							this.current.length = 0;
						}
						return;
					}
			}
        }
        // If we get here, we're out of source, so just make EOF tokens.
        this.tokenOffset = this.currentOffset;
        makeToken(TOKEN_EOF);
    }


	public inline function parse():Array<Dynamic> {
		return [];
	}
}
