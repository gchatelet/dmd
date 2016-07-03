Declaration {
    Type type;
    StorageClass storage_class;
    Prot protection;
    LINK linkage;
}

VarDeclaration : Declaration {
    Type type;                  // from declaration
}

FuncDeclaration : Declaration {
    Type type;                  // from Declaration is TypeFunction
    VarDeclarations* parameters
}

TypeFunction : TypeNext {
    Type next;                  // from TypeNext is return type
    Parameters* parameters;     // function parameters
    int varargs;                // 1: T t, ...) style for variable number of arguments
                                // 2: T t ...) style for variable number of arguments
    bool isnothrow;             // true: nothrow
    bool isnogc;                // true: is @nogc
    bool isproperty;            // can be called without parentheses
    bool isref;                 // true: returns a reference
    bool isreturn;              // true: 'this' is returned by ref
    LINK linkage;               // calling convention
    Expressions* fargs;         // function arguments
}

Parameter {
    StorageClass storageClass;
    Type type;
    Identifier ident;
}

// e.g. foo!(args) => name = foo, tiargs = args
TemplateInstance {
    Identifier name;
    TemplateDeclaration tempdecl;

    // Array of Types/Expressions of template instance arguments [int*, char, 10*10]
    Objects* tiargs;

    // Array of Types/Expressions corresponding to TemplateDeclaration.parameters [int, char, 100]
    Objects tdtypes;

    // for function template, these are the function arguments
    Expressions* fargs;
}

// e.g. void foo(A, B)()
TemplateDeclaration : ScopeDsymbol {
    // These are the template parameters.
    // i.e. void foo(A, B)();
    //               ^  ^
    TemplateParameters* parameters;
    Dsymbol onemember; // can be FuncDeclaration
}

TemplateParameter {
    Identifer ident;

    MATCH matchArg(Loc instLoc, Scope* sc, Objects* tiargs, size_t i, TemplateParameters* parameters, Objects* dedtypes, Declaration* psparam)
}

TemplateAliasParameter : TemplateParameter {}
TemplateTupleParameter : TemplateParameter {}
TemplateTypeParameter  : TemplateParameter {}
TemplateThisParameter  : TemplateParameter {}
TemplateValueParameter : TemplateParameter {}

-------------------------------------------------------------------------------
// TemplateDeclaration
void foo(T)(int, ref T);
         ^
 TemplateParameters

// TypeFunction tf = onemember.isFuncDeclaration().type
void foo(T)(int, ref T);
^^^^        ^^^^^^^^^^
tf.next     tf.parameters 

// TemplateInstance
foo!(int*)
     ^^^^
    tdtypes