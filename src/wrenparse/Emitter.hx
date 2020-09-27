package wrenparse;

// Emit bytecode
class Emitter{
    /**
     * The maximum number of module-level variables that may be defined at one time.
     * This limitation comes from the 16 bits used for the arguments to
     * `CODE_LOAD_MODULE_VAR` and `CODE_STORE_MODULE_VAR`.
     */
    public static final MAX_MODULE_VARS=65536;

    /**
     * The maximum number of arguments that can be passed to a method. Note that
     * this limitation is hardcoded in other places in the VM, in particular, the
     * `CODE_CALL_XX` instructions assume a certain maximum number.
     */
    public static final MAX_PARAMETERS=16;

    /**
     * The maximum name of a method, not including the signature.
     */
    public static final MAX_METHOD_NAME=64;
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
    public static final MAX_METHOD_SIGNATURE=(MAX_METHOD_NAME + (MAX_PARAMETERS * 2) + 6);
    /**
     * The maximum length of an identifier. The only real reason for this limitation
     * is so that error messages mentioning variables can be stack allocated.
     */
    public static final MAX_VARIABLE_NAME=64;
    /**
     * The maximum number of fields a class can have, including inherited fields.
     * This is explicit in the bytecode since `CODE_CLASS` and `CODE_SUBCLASS` take
     * a single byte for the number of fields. Note that it's 255 and not 256
     * because creating a class takes the *number* of fields, not the *highest
     * field index*.
     */
    public static final MAX_FIELDS=255;

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
    public static final MAX_INTERPOLATION_NESTING=8;

}