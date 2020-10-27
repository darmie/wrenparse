package wrenparse;

import wrenparse.objects.ObjString;
import wrenparse.Data;

@:allow(wrenparse.Compiler)
class Grammar {
	static function bareName(compiler:Compiler, canAssign:Bool, variable:Variable) {
		// If there's an "=" after a bare name, it's a variable assignment.
		if (canAssign && compiler.match(TOKEN_EQ)) {
			// Compile the right-hand side.
			compiler.expression();

			// Emit the store instruction.
			switch (variable.scope) {
				case SCOPE_LOCAL:
					compiler.emitByteArg(CODE_STORE_LOCAL, variable.index);

				case SCOPE_UPVALUE:
					compiler.emitByteArg(CODE_STORE_UPVALUE, variable.index);

				case SCOPE_MODULE:
					compiler.emitShortArg(CODE_STORE_MODULE_VAR, variable.index);

				default:
					Utils.UNREACHABLE();
			}
			return;
		}

		// Emit the load instruction.
		compiler.loadVariable(variable);
	}

	/**
	 * Compiles a variable name or method call with an implicit receiver.
	 * @param compiler
	 * @param canAssign
	 */
	public static function name(compiler:Compiler, canAssign:Bool) {
		// Look for the name in the scope chain up to the nearest enclosing method.
        var token:Token = compiler.parser.previous;
		var variable = compiler.resolveNonmodule(token.start);
		if (variable.index != -1) {
			bareName(compiler, canAssign, variable);
			return;
		}

		// TODO: The fact that we return above here if the variable is known and parse
		// an optional argument list below if not means that the grammar is not
		// context-free. A line of code in a method like "someName(foo)" is a parse
		// error if "someName" is a defined variable in the surrounding scope and not
		// if it isn't. Fix this. One option is to have "someName(foo)" always
		// resolve to a self-call if there is an argument list, but that makes
		// getters a little confusing.

		// If we're inside a method and the name is lowercase, treat it as a method
		// on this.

		if (Utils.isLocalName(token.start) && Utils.getEnclosingClass(compiler) != null) {
			compiler.loadThis();
			namedCall(compiler, canAssign, CODE_CALL_0);
			return;
		}

		// Otherwise, look for a module-level variable with the name.
		variable.scope = SCOPE_MODULE;
		variable.index = compiler.parser.module.variableNames.find(token.start);

		if (variable.index == -1) {
			// Implicitly define a module-level variable in
			// the hopes that we get a real definition later.
			variable.index = compiler.parser.module.declareVariable(compiler.parser.vm, token.start, token.line);

			if (variable.index == -2) {
				compiler.error("Too many module variables defined.");
			}
		}

		bareName(compiler, canAssign, variable);
	}

	public static function null_(compiler:Compiler, canAssign:Bool) {
		compiler.emitOp(CODE_NULL);
	}

	/**
	 * A parenthesized expression.
	 * @param compiler
	 * @param canAssign
	 */
	public static function grouping(compiler:Compiler, canAssign:Bool) {
		compiler.expression();
		compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after expression.");
	}

	/**
	 * A list literal.
	 * @param compiler
	 * @param canAssign
	 */
	public static function list(compiler:Compiler, canAssign:Bool) {
		// Instantiate a new list.
		compiler.loadCoreVariable("List");
		compiler.callMethod(0, "new()");

		// Compile the list elements. Each one compiles to a ".add()" call.
		do {
			compiler.ignoreNewlines();

			// Stop if we hit the end of the list.
			if (compiler.peek() == TOKEN_RIGHT_BRACKET)
				break;

			// The element.
			compiler.expression();
			compiler.callMethod(1, "addCore_(_)");
		} while (compiler.match(TOKEN_COMMA));

			// Allow newlines before the closing ']'.
		compiler.ignoreNewlines();
		compiler.consume(TOKEN_RIGHT_BRACKET, "Expect ']' after list elements.");
	}

	/**
	 * A map literal.
	 * @param compiler
	 * @param canAssign
	 */
	public static function map(compiler:Compiler, canAssign:Bool) {
		// Instantiate a new map.
		compiler.loadCoreVariable("Map");
		compiler.callMethod(0, "new()");

		// Compile the map elements. Each one is compiled to just invoke the
		// subscript setter on the map.
		do {
			compiler.ignoreNewlines();

			// Stop if we hit the end of the map.
			if (compiler.peek() == TOKEN_RIGHT_BRACE)
				break;

			// The key.
			compiler.parsePrecedence(PREC_UNARY);
			compiler.consume(TOKEN_COLON, "Expect ':' after map key.");
			compiler.ignoreNewlines();

			// The value.
			compiler.expression();
			compiler.callMethod(2, "addCore_(_,_)");
		} while (compiler.match(TOKEN_COMMA));

			// Allow newlines before the closing '}'.
		compiler.ignoreNewlines();
		compiler.consume(TOKEN_RIGHT_BRACKET, "Expect '}' after map elements.");
	}

	public static function boolean(compiler:Compiler, canAssign:Bool) {
		compiler.emitOp(compiler.parser.previous.type == TOKEN_FALSE ? CODE_FALSE : CODE_TRUE);
	}

	/**
	 * A number or string literal.
	 * @param compiler
	 * @param canAssign
	 */
	public static function literal(compiler:Compiler, canAssign:Bool) {
        if(compiler.parser.isDigit(compiler.parser.previous.start)){
            compiler.parser.previous.value = Value.NUM_VAL(Std.parseFloat(compiler.parser.previous.start));
        } else {
            compiler.parser.previous.value = ObjString.newString(compiler.parser.vm, compiler.parser.previous.start);
        }

		compiler.emitConstant(compiler.parser.previous.value);
	}

	/**
	 * A string literal that contains interpolated expressions.
	 *
	 * Interpolation is syntactic sugar for calling ".join()" on a list. So the
	 * string:
	 *
	 *      "a %(b + c) d"
	 *
	 * is compiled roughly like:
	 *
	 *      ["a ", b + c, " d"].join()
	 *
	 * @param compiler
	 * @param canAssign
	 */
	public static function stringInterpolation(compiler:Compiler, canAssign:Bool) {
		// Instantiate a new list.
		compiler.loadCoreVariable("List");
		compiler.callMethod(0, "new()");

		do {
			// The opening string part.
			literal(compiler, false);
			compiler.callMethod(1, "addCore_(_)");

			// The interpolated expression.
			compiler.ignoreNewlines();
			compiler.expression();
			compiler.callMethod(1, "addCore_(_)");

			compiler.ignoreNewlines();
		} while (compiler.match(TOKEN_INTERPOLATION));

			// The trailing string part.
		compiler.consume(TOKEN_STRING, "Expect end of string interpolation.");
		literal(compiler, false);
		compiler.callMethod(1, "addCore_(_)");
		// The list of interpolated parts.
		compiler.callMethod(0, "join()");
	}

	public static function super_(compiler:Compiler, canAssign:Bool) {
		var enclosingClass = Utils.getEnclosingClass(compiler);
		if (enclosingClass == null) {
			compiler.error("Cannot use 'super' outside of a method.");
		}
		compiler.loadThis();
		// TODO: Super operator calls.
		// TODO: There's no syntax for invoking a superclass constructor with a
		// different name from the enclosing one. Figure that out.

		// See if it's a named super call, or an unnamed one.

		if (compiler.match(TOKEN_DOT)) {
			// Compile the superclass call.
			compiler.consume(TOKEN_NAME, "Expect method name after 'super.'.");
			namedCall(compiler, canAssign, CODE_SUPER_0);
		} else if (enclosingClass != null) {
			// No explicit name, so use the name of the enclosing method. Make sure we
			// check that enclosingClass isn't NULL first. We've already reported the
			// error, but we don't want to crash here.
			methodCall(compiler, CODE_SUPER_0, enclosingClass.signature);
		}
	}

	public static function this_(compiler:Compiler, canAssign:Bool) {
		if (Utils.getEnclosingClass(compiler) == null) {
			compiler.error("Cannot use 'this' outside of a method.");
			return;
		}

		compiler.loadThis();
	}

	public static function field(compiler:Compiler, canAssign:Bool) {
		// Initialize it with a fake value so we can keep parsing and minimize the
		// number of cascaded errors.

		var field = Compiler.MAX_FIELDS;
		var enclosingClass = Utils.getEnclosingClass(compiler);
		if (enclosingClass == null) {
			compiler.error("Cannot reference a field outside of a class definition.");
		} else if (enclosingClass.isForeign) {
			compiler.error("Cannot define fields in a foreign class.");
		} else if (enclosingClass.inStatic) {
			compiler.error("Cannot use an instance field in a static method.");
		} else {
			// Look up the field, or implicitly define it.
			
			field = enclosingClass.fields.ensure(compiler.parser.previous.start);
			if (field >= Compiler.MAX_FIELDS) {
				compiler.error('A class can only have ${Compiler.MAX_FIELDS} fields.');
			}
		}

		// If there's an "=" after a field name, it's an assignment.
		var isLoad = true;
		if (canAssign && compiler.match(TOKEN_EQ)) {
			// Compile the right-hand side.
			compiler.expression();
			isLoad = false;
		}

		// If we're directly inside a method, use a more optimal instruction.
		if (compiler.parent != null && compiler.parent.enclosingClass == enclosingClass) {
			compiler.emitByteArg(isLoad ? CODE_LOAD_FIELD_THIS : CODE_STORE_FIELD_THIS, field);
		} else {
			compiler.loadThis();
			compiler.emitByteArg(isLoad ? CODE_LOAD_FIELD : CODE_STORE_FIELD, field);
		}
	}

	public static function staticField(compiler:Compiler, canAssign:Bool) {
		var classCompiler = Utils.getEnclosingClassCompiler(compiler);
		if (classCompiler == null) {
			compiler.error("Cannot use a static field outside of a class definition.");
			return;
		}

		// Look up the name in the scope chain.
		var token = compiler.parser.previous;
		// If this is the first time we've seen this static field, implicitly
		// define it as a variable in the scope surrounding the class definition.
		if (classCompiler.resolveLocal(token.start) == -1) {
			var symbol = classCompiler.declareVariable(null);

			// Implicitly initialize it to null.
			classCompiler.emitOp(CODE_NULL);
			classCompiler.defineVariable(symbol);
		}

		// It definitely exists now, so resolve it properly. This is different from
		// the above resolveLocal() call because we may have already closed over it
		// as an upvalue.
		var variable = compiler.resolveName(token.start);
		bareName(compiler, canAssign, variable);
	}

	/**
	 * Subscript or "array indexing" operator like `foo[bar]`.
	 * @param compiler
	 * @param canAssign
	 */
	public static function subscript(compiler:Compiler, canAssign:Bool) {
		var signature:Signature = {
			name: "",
			length: 0,
			type: SIG_SUBSCRIPT,
			arity: 0
		};

		// Parse the argument list.
		finishArgumentList(compiler, signature);
		compiler.consume(TOKEN_RIGHT_BRACKET, "Expect ']' after arguments.");

		if (canAssign && compiler.match(TOKEN_EQ)) {
			signature.type = SIG_SUBSCRIPT_SETTER;

			// Compile the assigned value.
			compiler.validateNumParameters(++signature.arity);
			compiler.expression();
		}

		compiler.callSignature(CODE_CALL_0, signature);
	}

	public static function call(compiler:Compiler, canAssign:Bool) {
		compiler.ignoreNewlines();
		compiler.consume(TOKEN_NAME, "Expect method name after '.'.");
		namedCall(compiler, canAssign, CODE_CALL_0);
	}

	public static function and_(compiler:Compiler, canAssign:Bool) {
		compiler.ignoreNewlines();

		// Skip the right argument if the left is false.
		var jump = compiler.emitJump(CODE_AND);
		compiler.parsePrecedence(PREC_LOGICAL_AND);
		compiler.patchJump(jump);
	}

	public static function or_(compiler:Compiler, canAssign:Bool) {
		compiler.ignoreNewlines();

		// Skip the right argument if the left is false.
		var jump = compiler.emitJump(CODE_OR);
		compiler.parsePrecedence(PREC_LOGICAL_OR);
		compiler.patchJump(jump);
	}

	public static function conditional(compiler:Compiler, canAssign:Bool) {
		// Ignore newline after '?'.
		compiler.ignoreNewlines();

		// Jump to the else branch if the condition is false.
		var ifJump = compiler.emitJump(CODE_JUMP_IF);

		// Compile the then branch.
		compiler.parsePrecedence(PREC_CONDITIONAL);

		compiler.consume(TOKEN_COLON, "Expect ':' after then branch of conditional operator.");
		compiler.ignoreNewlines();

		// Jump over the else branch when the if branch is taken.
		var elseJump = compiler.emitJump(CODE_JUMP);

		// Compile the else branch.
		compiler.patchJump(ifJump);

		compiler.parsePrecedence(PREC_ASSIGNMENT);

		// Patch the jump over the else.
		compiler.patchJump(elseJump);
	}

	public static function infixOp(compiler:Compiler, canAssign:Bool) {
		var rule = compiler.getRule(compiler.parser.previous.type);

		// An infix operator cannot end an expression.
		compiler.ignoreNewlines();

		// Compile the right-hand side.
		compiler.parsePrecedence(rule.precedence + 1);

		// Call the operator method on the left-hand side.
		var signature:Signature = {
			name: rule.name,
			length: rule.name.length,
			type: SIG_METHOD,
			arity: 1
		};
		compiler.callSignature(CODE_CALL_0, signature);
	}

	/**
	 * Compiles a method signature for an infix operator.
	 * @param compiler
	 * @param signature
	 */
	public static function infixSignature(compiler:Compiler, signature:Signature) {
		// Add the RHS parameter.
		signature.type = SIG_METHOD;
		signature.arity = 1;
		// Parse the parameter name.
		compiler.consume(TOKEN_LEFT_PAREN, "Expect '(' after operator name.");
		compiler.declareNamedVariable();
		compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after parameter name.");
	}

	/**
	 * Unary operators like `-foo`.
	 * @param compiler
	 * @param canAssign
	 */
	public static function unaryOp(compiler:Compiler, canAssign:Bool) {
		var rule = compiler.getRule(compiler.parser.previous.type);
		compiler.ignoreNewlines();
		// Compile the argument.
		compiler.parsePrecedence((PREC_UNARY + 1));
		// Call the operator method on the left-hand side.
		compiler.callMethod(0, rule.name);
	}

	/**
	 * Compiles a method signature for an unary operator (i.e. "!").
	 * @param compiler
	 * @param signature
	 */
	public static function unarySignature(compiler:Compiler, signature:Signature) {
		// Do nothing. The name is already complete.
		signature.type = SIG_GETTER;
	}

	/**
	 * Compiles a method signature for an operator that can either be unary or
	 * infix (i.e. "-").
	 * @param compiler
	 * @param signature
	 */
	public static function mixedSignature(compiler:Compiler, signature:Signature) {
		signature.type = SIG_GETTER;
		// If there is a parameter, it's an infix operator, otherwise it's unary.
		if (compiler.match(TOKEN_LEFT_PAREN)) {
			// Add the RHS parameter.
			signature.type = SIG_METHOD;
			signature.arity = 1;

			// Parse the parameter name.
			compiler.declareNamedVariable();
			compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after parameter name.");
		}
	}

	/**
	 * Compiles an optional setter parameter in a method [signature].
	 *
	 * Returns `true` if it was a setter.
	 * @param compiler
	 * @param signature
	 * @return Bool
	 */
	static function maybeSetter(compiler:Compiler, signature:Signature):Bool {
		// See if it's a setter.
		if (!compiler.match(TOKEN_EQ))
			return false;

		// It's a setter.
		if (signature.type == SIG_SUBSCRIPT) {
			signature.type = SIG_SUBSCRIPT_SETTER;
		} else {
			signature.type = SIG_SETTER;
		}

		// Parse the value parameter.
		compiler.consume(TOKEN_LEFT_PAREN, "Expect '(' after '='.");
		compiler.declareNamedVariable();
		compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after parameter name.");

		signature.arity++;

		return true;
	}

	/**
	 * Compiles a method signature for a subscript operator.
	 * @param compiler
	 * @param signature
	 */
	public static function subscriptSignature(compiler:Compiler, signature:Signature) {
		signature.type = SIG_SUBSCRIPT;

		// The signature currently has "[" as its name since that was the token that
		// matched it. Clear that out.
		signature.length = 0;

		// Parse the parameters inside the subscript.
		finishParameterList(compiler, signature);
		compiler.consume(TOKEN_RIGHT_BRACKET, "Expect ']' after parameters.");

		maybeSetter(compiler, signature);
	}

	/**
	 * Compiles a method signature for a named method or setter.
	 * @param compiler
	 * @param signature
	 */
	public static function namedSignature(compiler:Compiler, signature:Signature) {
		signature.type = SIG_GETTER;
      
		// If it's a setter, it can't also have a parameter list.
		if (maybeSetter(compiler, signature))
			return;

		// Regular named method with an optional parameter list.
		parameterList(compiler, signature);
	}

	/**
	 * Compiles a method signature for a constructor.
	 * @param compiler
	 * @param signature
	 */
	public static function constructorSignature(compiler:Compiler, signature:Signature) {
		compiler.consume(TOKEN_NAME, "Expect constructor name after 'construct'.");
		
		// Capture the name.
		signature = compiler.signatureFromToken(SIG_INITIALIZER);

		if (compiler.match(TOKEN_EQ)) {
			compiler.error("A constructor cannot be a setter.");
		}

		if (!compiler.match(TOKEN_LEFT_PAREN)) {
			compiler.error("A constructor cannot be a getter.");
			return;
		}

		// Allow an empty parameter list.
		if (compiler.match(TOKEN_RIGHT_PAREN))
			return;

		finishParameterList(compiler, signature);
		compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after parameters.");
	}

	/**
	 * Parses an optional parenthesized parameter list. Updates `type` and `arity`
	 * in [signature] to match what was parsed.
	 *
	 * @param compiler
	 * @param signature
	 */
	static function parameterList(compiler:Compiler, signature:Signature) {
		// The parameter list is optional.
		if (!compiler.match(TOKEN_LEFT_PAREN))
			return;

		signature.type = SIG_METHOD;
		// Allow an empty parameter list.
		if (compiler.match(TOKEN_RIGHT_PAREN))
			return;

        
        finishParameterList(compiler, signature);
       
		compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after parameters.");
	}

	/**
	 * Parses a comma-separated list of arguments. Modifies [signature] to include
	 * the arity of the argument list.
	 * @param compiler
	 * @param signature
	 */
	static function finishArgumentList(compiler:Compiler, signature:Signature) {
		do {
			compiler.ignoreNewlines();
			compiler.validateNumParameters(++signature.arity);
			compiler.expression();
		} while (compiler.match(TOKEN_COMMA));

			// Allow a newline before the closing delimiter.
		compiler.ignoreNewlines();
	}

	/**
	 * Parses the rest of a comma-separated parameter list after the opening
	 * delimeter. Updates `arity` in [signature] with the number of parameters.
	 * @param compiler
	 * @param signature
	 */
	static function finishParameterList(compiler:Compiler, signature:Signature) {
		do {
			compiler.ignoreNewlines();
			compiler.validateNumParameters(++signature.arity);

			// Define a local variable in the method for the parameter.
			compiler.declareNamedVariable();
        } while (compiler.match(TOKEN_COMMA));
        
	}

	/**
	 * Parses a block body, after the initial "{" has been consumed.
	 *
	 * Returns true if it was a expression body, false if it was a statement body.
	 * (More precisely, returns true if a value was left on the stack. An empty
	 * block returns false.)
	 * @param compiler
	 */
	static function finishBlock(compiler:Compiler) {
		// Empty blocks do nothing.
		if (compiler.match(TOKEN_RIGHT_BRACE))
			return false;

        // trace(compiler.peek());
		// If there's no line after the "{", it's a single-expression body.
		if (!compiler.matchLine()) {

			compiler.expression();
			compiler.consume(TOKEN_RIGHT_BRACE, "Expect '}' at end of block.");
			return true;
		}

        
		// Empty blocks (with just a newline inside) do nothing.
		if (compiler.match(TOKEN_RIGHT_BRACE))
            return false;
        

		// Compile the definition list.
		do {            
            compiler.definition();
			compiler.consumeLine("Expect newline after statement.");
		} while (compiler.peek() != TOKEN_RIGHT_BRACE && compiler.peek() != TOKEN_EOF);

		compiler.consume(TOKEN_RIGHT_BRACE, "Expect '}' at end of block.");
		return false;
	}

	/**
	 * Parses a method or function body, after the initial "{" has been consumed.
	 *
	 * It [isInitializer] is `true`, this is the body of a constructor initializer.
	 * In that case, this adds the code to ensure it returns `this`.
	 * @param compiler
	 * @param initializer
	 */
	static function finishBody(compiler:Compiler, isInitializer:Bool) {
		var isExpressionBody = finishBlock(compiler);
		if (isInitializer) {
			// If the initializer body evaluates to a value, discard it.
			if (isExpressionBody)
				compiler.emitOp(CODE_POP);

			// The receiver is always stored in the first local slot.
			compiler.emitOp(CODE_LOAD_LOCAL_0);
		} else if (!isExpressionBody) {
			// Implicitly return null in statement bodies.
			compiler.emitOp(CODE_NULL);
		}

		compiler.emitOp(CODE_RETURN);
	}

	/**
	 * Compiles a call whose name is the previously consumed token. This includes
	 * getters, method calls with arguments, and setter calls.
	 * @param compiler
	 * @param canAssign
	 * @param code
	 */
	public static function namedCall(compiler:Compiler, canAssign:Bool, instruction:Code) {
        // Get the token for the method name.
        var signature = compiler.signatureFromToken(SIG_GETTER);
        
		if (canAssign && compiler.match(TOKEN_EQ)) {
			compiler.ignoreNewlines();

			// Build the setter signature.
			signature.type = SIG_SETTER;
			signature.arity = 1;

			// Compile the assigned value.
			compiler.expression();
			compiler.callSignature(instruction, signature);
		} else {
			methodCall(compiler, instruction, signature);
		}
	}

	/**
	 * Compiles an (optional) argument list for a method call with [methodSignature]
	 * and then calls it.
	 * @param instruction
	 * @param signature
	 */
	public static function methodCall(compiler:Compiler, instruction:Code, signature:Signature) {
		// Make a new signature that contains the updated arity and type based on
		// the arguments we find.
		var called:Signature = {
			name: signature.name,
			length: signature.length,
			type: SIG_GETTER,
			arity: 0
		}

		// Parse the argument list, if any.
		if (compiler.match(TOKEN_LEFT_PAREN)) {
			called.type = SIG_METHOD;

			// Allow empty an argument list.
			if (compiler.peek() != TOKEN_RIGHT_PAREN) {
				finishArgumentList(compiler, called);
			}
			compiler.consume(TOKEN_RIGHT_PAREN, "Expect ')' after arguments.");
		}

		// Parse the block argument, if any.
		if (compiler.match(TOKEN_LEFT_BRACE)) {
			// Include the block argument in the arity.
			called.type = SIG_METHOD;
			called.arity++;

			var fnCompiler:Compiler = Compiler.init(compiler.parser, compiler, false);
			// Make a dummy signature to track the arity.
			var fnSignature:Signature = {
				name: "",
				length: 0,
				type: SIG_METHOD,
				arity: 0
			};

			// Parse the parameter list, if any.
			if (compiler.match(TOKEN_PIPE)) {
				finishParameterList(fnCompiler, fnSignature);
				compiler.consume(TOKEN_PIPE, "Expect '|' after function parameters.");
			}

			fnCompiler.fn.arity = fnSignature.arity;
			finishBody(fnCompiler, false);

			// Name the function based on the method its passed to.
			var blockName:String = cast called;
			blockName += " block argument";

			fnCompiler.endCompiler(blockName);
		}
		// TODO: Allow Grace-style mixfix methods?

		// If this is a super() call for an initializer, make sure we got an actual
		// argument list.
		if (signature.type == SIG_INITIALIZER) {
			if (called.type != SIG_METHOD) {
				compiler.error("A superclass constructor must have an argument list.");
			}

			called.type = SIG_INITIALIZER;
		}

		compiler.callSignature(instruction, called);
	}
}
