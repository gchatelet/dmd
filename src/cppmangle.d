/**
 * Compiler implementation of the $(LINK2 http://www.dlang.org, D programming language)
 *
 * Copyright: Copyright (c) 1999-2016 by Digital Mars, All Rights Reserved
 * Authors: Walter Bright, http://www.digitalmars.com
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(DMDSRC _cppmangle.d)
 */

module ddmd.cppmangle;

import core.stdc.string;
import core.stdc.stdio;

import ddmd.arraytypes;
import ddmd.declaration;
import ddmd.dsymbol;
import ddmd.dtemplate;
import ddmd.errors;
import ddmd.expression;
import ddmd.func;
import ddmd.globals;
import ddmd.id;
import ddmd.mtype;
import ddmd.root.outbuffer;
import ddmd.root.rootobject;
import ddmd.target;
import ddmd.tokens;
import ddmd.visitor;

/* Do mangling for C++ linkage.
 * No attempt is made to support mangling of templates, operator
 * overloading, or special functions.
 *
 * So why don't we use the C++ ABI for D name mangling?
 * Because D supports a lot of things (like modules) that the C++
 * ABI has no concept of. These affect every D mangled name,
 * so nothing would be compatible anyway.
 */
static if (TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_OPENBSD || TARGET_SOLARIS)
{
    //-------------------------------------------------------------------------
    // Newer implementation.
    //-------------------------------------------------------------------------
    private static void writeBase36(size_t i, ref const(char)[] output) {
        if (i >= 36) {
            writeBase36(i / 36, output);
            i %= 36;
        }
        if (i < 10)
            output ~= cast(char)(i + '0');
        else if (i < 36)
            output ~= cast(char)(i - 10 + 'A');
        else
            assert(0);
    }

    private static void writeBase10(size_t i, ref const(char)[] output) {
        if (i >= 10) {
            writeBase10(i / 10, output);
            i %= 10;
        }
        if (i < 10)
            output ~= cast(char)(i + '0');
        else
            assert(0);
    }

    private static void writeSubstitution(in size_t index, in char type, ref const(char)[] buffer) {
        buffer ~= type;
        if (index >= 1) writeBase36(index - 1, buffer);
        buffer ~= '_';
    }

    private struct BufferRange {
        bool contains(in BufferRange other) const { return start <= other.start && end >= other.end; }
        void print() const { printf(" [%d, %d]", start, end); }
        size_t start;
        size_t end;
    }

    private static int print(in BufferRange range, const(char)[] buffer) {
        with(range) {
            return printf("%*s%.*s", start, "".ptr, end - start, buffer.ptr + start);
        }
    }

    private static void printSub(size_t index) {
        printf("S");
        if(index > 0) printf("%d", index - 1);
        printf("_");
    }

    class Buffer {
        void appendSourceName(string name, LINK linkage = LINKcpp) {
            if(linkage == LINKcpp) writeBase10(name.length, buffer);
            buffer ~= name;
        }

        const(char)[] opIndex(in BufferRange range) const {
            return buffer[range.start .. range.end];
        }

        const(char)[] buffer;
        alias buffer this;
    }

    class Substitutions {
        this(Buffer buffer) { this.buffer = buffer; }

        static bool isBasicType(CppNode node) {
            return node.isSymbol && node.isSymbol.isBasicType;
        }

        static bool isBareDeclaration(CppNode node) {
            if(auto symbol = node.isSymbol) {
                return symbol.isDeclaration && symbol.tmpl is null;
            }
            return false;
        }

        private string key(in BufferRange range) {
            return buffer[range].idup;
        }

        private struct Sub {
            BufferRange range;
            size_t index;
            void append(ref const(char)[] buffer) const {
                writeSubstitution(index, 'S', buffer);
            }
        }

        public SymbolTracker track(CppNode node) {
            return SymbolTracker(node, this, buffer.length);
        }

        private void pushSymbolRange(size_t start, CppNode node) {
            // Discard basic type and non templated declarations, they are never substitutable.
            if(isBasicType(node) || isBareDeclaration(node)) return;
            const range = BufferRange(start, buffer.length);
            const printed = print(range, buffer); printf("%*s", 80 - printed, "".ptr);
            const key = key(range);
            substituteOrAddSymbol(key, range);
            range.print(); printf("\n");
        }

        private void substituteOrAddSymbol(string key, in BufferRange range) {
            if(auto found = key in symbols) {
                addSymbolSubstitution(*found, range);
            } else {
                printf("ADD SYM "); printSub(symbols.length);
                symbols[key] = Sub(range, symbols.length);
            }
        }

        private void addSymbolSubstitution(in Sub found, in BufferRange range) {
            printf("SUB SYM ", found.index); printSub(found.index);
            // Coalesce substitutions. i.e. if a new substitution contains
            // the previous ones it takes them over.
            while(subs.length &&range.contains(subs[$-1].range)) {
                --subs.length;
                printf(" [sup]");
            }
            subs ~= Sub(range, found.index);
        }

        public const(char)* finish() const {
            printf("%.*s |<\n", buffer.length, buffer.ptr);
            const(char)[] new_buffer;
            {
                size_t start;
                foreach(const ref sub; subs) {
                    new_buffer ~= buffer[BufferRange(start, sub.range.start)];
                    sub.append(new_buffer);
                    start = sub.range.end;
                }
                new_buffer ~= buffer[start .. $];
            }
            new_buffer ~= '\0';
            printf("%s |>\n", new_buffer.ptr);
            return new_buffer.ptr;
        }

        Buffer buffer;
        Sub[string] symbols;
        Sub[] subs;
    }

    private struct SymbolTracker {
        @disable this(this);
        this(CppNode node, Substitutions substitutions, size_t start) {
            assert(node);
            this.node = node;
            this.substitutions = substitutions;
            this.start = start;
        }

        ~this() {
            substitutions.pushSymbolRange(start, node);
        }

        CppNode node;
        size_t start;
        Substitutions substitutions;
    }

    interface OutputBuffer {
        // Buffer operations
        void append(char c);
        void append(const(char)[] other);
        void appendSourceName(string name);
        const(char)* finish();
        // State tracking
        SymbolTracker track(CppNode node);
        ScopeTracker track_scope();

        bool isRootScope() const;
    }

    class Context : OutputBuffer {
        this() {
            buffer = new Buffer;
            substitutions = new Substitutions(buffer);
        }
        override void append(char c) { buffer ~= c; }
        override void append(const(char)[] other) { buffer ~= other; }
        override void appendSourceName(string name) { buffer.appendSourceName(name, mangleAsCpp ? LINKcpp : LINKc); }
        override const(char)* finish() { return substitutions.finish(); }

        ////////////////////////////////////////////////////////////////////////
        override SymbolTracker track(CppNode node) { return substitutions.track(node); }
        override ScopeTracker track_scope() { return ScopeTracker(this); }
        override bool isRootScope() const { return scope_counter == 0; }

        ////////////////////////////////////////////////////////////////////////
        scope Buffer buffer;
        scope Substitutions substitutions;
        bool mangleAsCpp = false;
        int scope_counter = 0;
    }

    private struct ScopeTracker {
        @disable this(this);
        this(Context output) { this.output = output; ++output.scope_counter; }
        ~this() { --output.scope_counter; }
        Context output;
    }

    bool isNested(CppNode node) {
        assert(node);
        while(node.isIndirection) node = node.isIndirection.next;
        auto symbol = node.isSymbol;
        assert(symbol);
        return symbol.parent !is null;
    }

    class CppNode {
        CppIndirection isIndirection() { return null; }
        CppTemplateInstance isTemplateInstance() { return null; }
        CppSymbol isSymbol() { return null; }

        abstract void mangle(scope OutputBuffer output);
    }

    // Pointer, Reference or Const
    final class CppIndirection: CppNode {
        CppNode next;
        enum Kind : char { Pointer = 'P', Reference = 'R', Const = 'K' };
        Kind kind;

        this(CppNode node, Kind kind) {
            assert(node);
            this.next = node;
            this.kind = kind;
        }

        override CppIndirection isIndirection() { return this; }

        static CppIndirection toConst(CppNode node) { return new CppIndirection(node, Kind.Const); }
        static CppIndirection toPtr(CppNode node) { return new CppIndirection(node, Kind.Pointer); }
        static CppIndirection toRef(CppNode node) { return new CppIndirection(node, Kind.Reference); }

        override void mangle(scope OutputBuffer output) {
            const _ = output.track(this);
            output.append(kind);
            assert(next);
            next.mangle(output);
        }
    }

    final class CppTemplateInstance: CppNode {
        CppSymbol source;
        CppNode[] template_args;
        CppNode[] template_function_args;

        this(CppSymbol source) { this.source = source; }

        override CppTemplateInstance isTemplateInstance() { return this; }

        bool matchesSubstitutionTemplateArguments(size_t expected_arguments) {
            assert(expected_arguments > 0);
            return template_args.length == expected_arguments
                    && template_args[0].isSymbol
                    && template_args[0].isSymbol.isCharType;
        }

        override void mangle(scope OutputBuffer output) {
            output.append('I');
            foreach (argument ; template_args) argument.mangle(output);
            output.append('E');
        }

        void mangleFunctionArguments(scope OutputBuffer output) {
            foreach(arg; template_function_args) arg.mangle(output);
        }
    }

    final class CppSymbol: CppNode {
        string name;
        enum Kind { Namespace, Aggregate, Enum, Function, Basic, FuncDeclaration, VarDeclaration, Identifier};
        Kind kind;
        CppSymbol parent;
        CppSymbol declaration_type;
        bool is_declaration_type_const;
        CppTemplateInstance tmpl;
        CppNode function_return_type;
        CppNode[] function_args;

        this(string name, Kind kind) {
            this.name = name;
            this.kind = kind;
        }

        override CppSymbol isSymbol() { return this; }

        bool isCharType() { return kind == Kind.Basic && name == "c"; }
        bool isBasicType () { return kind == Kind.Basic; }
        bool isValueType () { return kind == Kind.Aggregate || kind == Kind.Basic; }
        bool isDeclaration() { return kind == Kind.VarDeclaration || kind == Kind.FuncDeclaration; }
        bool isAggregate() { return kind == Kind.Aggregate; }
        bool isScope() { return isAggregate() || kind == Kind.Namespace; }
        bool isStd() { return kind == Kind.Namespace && name == "std" && parent is null; }
        bool isAllocator() { return isAggregate() && name == "allocator" && parent && parent.isStd(); }
        bool isBasicString() { return isAggregate() && name == "basic_string" && parent && parent.isStd(); }
        bool isBasicStringInstance() { return isBasicString && tmpl && tmpl.matchesSubstitutionTemplateArguments(3); }
        bool isBasicStreamInstance(string type)() {
            static assert(type == "i" || type == "o" || type == "io");
            return isAggregate() && name == "basic_" ~ type ~ "stream" && parent && parent.isStd() && tmpl && tmpl.matchesSubstitutionTemplateArguments(2);
        }

        enum Abbreviation { NO, YES, YES_MANGLE_TMPL_ARGS }
        Abbreviation abbreviate(scope OutputBuffer output) {
            switch(kind) {
                case Kind.Namespace:
                case Kind.Aggregate:
                    if(isStd) {
                        output.append("St");
                    } else if (isBasicStreamInstance!"i") {
                        output.append("Si");
                    } else if (isBasicStreamInstance!"o") {
                        output.append("So");
                    } else if (isBasicStreamInstance!"io") {
                        output.append("Sd");
                    } else if (isBasicStringInstance) {
                        output.append("Ss");
                    } else if (isAllocator) {
                        output.append("Sa");
                        return Abbreviation.YES_MANGLE_TMPL_ARGS;
                    } else if (isBasicString) {
                        output.append("Sb");
                        return Abbreviation.YES_MANGLE_TMPL_ARGS;
                    } else {
                        return Abbreviation.NO;
                    }
                    return Abbreviation.YES;
                default:
                    return Abbreviation.NO;
            }
        }

        override void mangle(scope OutputBuffer output) {
            final switch(abbreviate(output)) {
                case Abbreviation.YES:
                    break;
                case Abbreviation.YES_MANGLE_TMPL_ARGS:
                    if(tmpl) tmpl.mangle(output);
                    break;
                case Abbreviation.NO:
                    final switch(kind) {
                        case Kind.Basic:
                            mangleBasicType(output);
                            break;
                        case Kind.Identifier:
                            mangleIdentifier(output);
                            break;
                        case Kind.Namespace:
                        case Kind.Enum:
                            const _ = output.track(this);
                            mangleParent(output);
                            output.appendSourceName(name);
                            break;
                        case Kind.Aggregate:
                            if (tmpl) {
                                const _ = output.track(this);
                                mangleAggregate(output);
                            } else {
                                mangleAggregate(output);
                            }
                            break;
                        case Kind.Function:
                            mangleFunction(output);
                            break;
                        case Kind.VarDeclaration:
                            mangleVarDeclaration(output);
                            break;
                        case Kind.FuncDeclaration:
                            mangleFuncDeclaration(output);
                            break;
                    }
                    break;
            }
        }

        void mangleParent(scope OutputBuffer output) {
            if(parent) {
                const _ = output.track_scope();
                parent.mangle(output);
            }
        }

        void mangleAggregate(scope OutputBuffer output) {
            const enclosed = isEnclosed() && output.isRootScope();
            if(enclosed) output.append('N');
            if(parent) {
                const _ = output.track(this);
                mangleParent(output);
                mangleSourceName(output);
            } else {
                mangleSourceName(output);
            }
            if(tmpl) tmpl.mangle(output);
            if(enclosed) output.append('E');
        }

        void mangleBasicType(scope OutputBuffer output) {
            const _ = output.track(this);
            output.append(name);
        }

        void mangleIdentifier(scope OutputBuffer output) {
            const _ = output.track(this);
            output.append(name);
        }

        void mangleSourceName(scope OutputBuffer output) {
            const _ = output.track(this);
            output.appendSourceName(name);
        }

        void mangleVarDeclaration(scope OutputBuffer output) {
            assert(kind == Kind.VarDeclaration);
            const enclosed = isEnclosed();
            if(enclosed) output.append('N');
            if(is_declaration_type_const) output.append('L');
            if(parent) parent.mangle(output);
            output.appendSourceName(name);
            if(enclosed) output.append('E');
        }

        void mangleFuncDeclaration(scope OutputBuffer output) {
            assert(kind == Kind.FuncDeclaration);
            assert(declaration_type);
            {
                const _ = output.track(this);
                const enclosed = isEnclosed();
                if(enclosed) output.append('N');
                if(is_declaration_type_const) output.append('K');
                mangleParent(output);
                output.appendSourceName(name);
                if(tmpl) tmpl.mangle(output);
                if(enclosed) output.append('E');
                if(!tmpl) declaration_type.mangleFunctionArguments(output);
            }
            if(tmpl) tmpl.mangleFunctionArguments(output);
        }

        void mangleFunctionArguments(scope OutputBuffer output) {
            assert(kind == Kind.Function);
            foreach(arg; function_args) arg.mangle(output);
        }

        void mangleFunction(scope OutputBuffer output) {
            const _ = output.track(this);
            assert(kind == Kind.Function);
            output.append('F');
            function_return_type.mangle(output);
            mangleFunctionArguments(output);
            output.append('E');
        }

        bool isEnclosed() {
            bool decl;
            bool std;
            size_t scopes;
            void walkUp(CppSymbol symbol) {
              decl |= symbol.isDeclaration;
              std |= symbol.isStd;
              if (symbol.isScope) ++scopes;
              if (symbol.parent) walkUp(symbol.parent);
            }
            walkUp(this);
            if(scopes == 1 && std) return false;
            if(decl && scopes > 0) return true;
            return scopes > 1 && !std;
        }
    }

    CppNode removeConstForValueType(CppNode node) {
        if (auto indirection = node.isIndirection) {
            if (auto symbol = indirection.next.isSymbol) {
                if (symbol.isValueType && indirection.kind == CppIndirection.Kind.Const) {
                    return symbol;
                }
            }
        }
        return node;
    }

    extern (C++) final class ScopeHierarchy: Visitor
    {
        import ddmd.dmodule;
        import ddmd.dclass;
        import ddmd.denum;
        import ddmd.dstruct;
        import ddmd.nspace;
        alias visit = super.visit;
        CppSymbol output;
        static auto create(Dsymbol s) {
            scope visitor = new this();
            s.accept(visitor);
            return visitor.output;
        }
        override void visit(Module e) { /* stop climbing symbols here */ }
        override void visit(EnumDeclaration e)  { output = create(e, CppSymbol.Kind.Enum); }
        override void visit(ClassDeclaration e) { output = create(e, CppSymbol.Kind.Aggregate); }
        override void visit(StructDeclaration e){ output = create(e, CppSymbol.Kind.Aggregate); }
        override void visit(Nspace e)           { output = create(e, CppSymbol.Kind.Namespace); }
        override void visit(VarDeclaration e)   { output = createDecl(e, CppSymbol.Kind.VarDeclaration); }
        override void visit(FuncDeclaration e)  { output = createDecl(e, CppSymbol.Kind.FuncDeclaration); }
        override void visit(TemplateInstance e) { e.error("Internal Compiler Error"); fatal(); }

        static TemplateInstance getParentTemplateInstance(Dsymbol decl) {
            if(!decl.parent) return null;
            return decl.parent.isTemplateInstance;
        }

        CppSymbol create(Dsymbol symbol, CppSymbol.Kind kind) {
            auto current = new CppSymbol(symbol.ident.toString.idup, kind);
            auto parentTemplateInstance = getParentTemplateInstance(symbol);
            if (parentTemplateInstance) {
                current.tmpl = createTemplateInstance(current, parentTemplateInstance);
                current.parent = create(parentTemplateInstance.parent);
            } else {
                current.parent = create(symbol.parent);
            }
            return current;
        }

        CppSymbol createDecl(Declaration symbol, CppSymbol.Kind kind) {
            if(auto decl = symbol.isVarDeclaration) {
                if (!(decl.storage_class & (STCextern | STCgshared))) {
                    decl.error("Internal Compiler Error: C++ static non- __gshared non-extern variables not supported");
                    fatal();
                }
            }
            auto current = create(symbol, kind);
            if (symbol.isFuncDeclaration) {
                auto node = TypeVisitor.create(symbol.type);
                if(auto indirection = node.isIndirection) {
                    node = indirection.next;
                }
                assert(node);
                assert(node.isSymbol);
                current.declaration_type = node.isSymbol;
            }
            if(symbol.type.isConst) {
                current.is_declaration_type_const = true;
            }
            return current;
        }

        CppSymbol getTypeIdentifier(CppNode node) {
            while(node.isIndirection) node = node.isIndirection.next;
            if(auto symbol = node.isSymbol)
                return symbol.kind == CppSymbol.Kind.Identifier ? symbol : null;
            return null;
        }

        CppTemplateInstance createTemplateInstance(CppSymbol source, TemplateInstance templateInstance) {
            auto output = new CppTemplateInstance(source);
            auto declaration = cast(TemplateDeclaration)templateInstance.tempdecl;
            assert(declaration);
            assert(declaration.parameters);
            import ddmd.identifier;
            string[string] template_identifiers;
            // These are the template parameters.
            // i.e. template<typename A, typename B> foo();
            //                        ^           ^
            foreach(i, parameter; *declaration.parameters) {
                if(parameter.ident) {
                    const(char)[] substitution;
                    writeSubstitution(i, 'T', substitution);
                    template_identifiers[parameter.ident.toString.idup] = substitution.idup;
                }
            }
            if (declaration.onemember) {
                FuncDeclaration fd = declaration.onemember.isFuncDeclaration();
                if (fd && fd.type) {
                    TypeFunction tf = cast(TypeFunction)fd.type;
                    assert(tf);
                    if(tf.next) {
                        output.template_function_args ~= TypeVisitor.create(tf.next);
                    }
                    // These are the templated function arguments.
                    if(tf.parameters) foreach(parameter; *tf.parameters) {
                        output.template_function_args ~= TypeVisitor.create(parameter.type);
                    }
                    // Changing template name into substitutions.
                    // e.g. template<typename A, typename B> foo();
                    // 'A' becomes 'T_', 'B' becomes 'T0_'.
                    foreach(arg; output.template_function_args) {
                        if(auto type_identifier = getTypeIdentifier(arg)) {
                            type_identifier.name = template_identifiers[type_identifier.name];
                        }
                    }
                }
            }
            auto arguments = templateInstance.tiargs;
            assert(arguments);
            if(arguments.dim) {
                foreach(argument; *arguments) {
                    if(argument.isType is null) {
                        templateInstance.error(Loc(), "Internal Compiler Error: can't mangle non type template argument");
                        fatal();
                    }
                    output.template_args ~= removeConstForValueType(TypeVisitor.create(cast(Type)argument));
                }
            } else {
                output.template_args ~= TypeVisitor.create(Type.tvoid);
            }
            return output;
        }
    }

    extern (C++) final class TypeVisitor: Visitor
    {
        alias visit = super.visit;

        override void visit(Type t) {
            if (t.isImmutable() || t.isShared())
            {
                t.error(Loc(), "Internal Compiler Error: shared or immutable types can not be mapped to C++ (%s)", t.toChars());
            }
            else
            {
                t.error(Loc(), "Internal Compiler Error: unsupported type %s\n", t.toChars());
            }
            fatal(); //Fatal, because this error should be handled in frontend
        }
        
        override void visit(TypeBasic s)      { output = createTypeBasic(s); }
        override void visit(TypeClass s)      { output = adaptClass(s, adaptConstness(s, ScopeHierarchy.create(s.sym))); }
        override void visit(TypeEnum s)       { output = adaptConstness(s, ScopeHierarchy.create(s.sym)); }
        override void visit(TypeFunction s)   { output = adaptConstness(s, createFunction(s)); }
        override void visit(TypeIdentifier s) { output = createIndentifier(s); }
        override void visit(TypePointer s)    { output = adaptConstness(s, CppIndirection.toPtr(create(s.next))); }
        override void visit(TypeReference s)  { output = adaptConstness(s, CppIndirection.toRef(create(s.next))); }
        override void visit(TypeStruct s)     { output = adaptConstness(s, ScopeHierarchy.create(s.sym)); }
        
        extern(D):
        CppNode output;

        static auto create(Type s) {
            scope visitor = new TypeVisitor();
            s.accept(visitor);
            return visitor.output;
        }

        CppNode adaptClass(TypeClass s, CppNode node) {
            if(s.sym.com) {
                error(Loc(), "Internal Compiler Error: can't mangle COM class for now", s);
                fatal();
            }
            // Adding reference semantic in case it's a D class.
            return !s.sym.cpp ? CppIndirection.toPtr(node) : node;
        }

        CppNode adaptConstness(Type type, CppNode node) {
            return type.isConst ? CppIndirection.toConst(node) : node;
        }

        CppSymbol createFunction(TypeFunction typeFun) {
            auto output = new CppSymbol("", CppSymbol.Kind.Function);
            assert(typeFun);
            assert(typeFun.next);
            output.function_return_type = removeConstForValueType(TypeVisitor.create(typeFun.next));
            assert(output.function_return_type);
            auto parameters = typeFun.parameters;
            assert(parameters);
            if(parameters.dim) {
                foreach(parameter; *parameters) {
                    CppNode type = TypeVisitor.create(parameter.type);
                    if(parameter.storageClass & STCref)
                        type = CppIndirection.toRef(type);
                    output.function_args ~= removeConstForValueType(type);
                }
            } else {
                output.function_args ~= TypeVisitor.create(Type.tvoid);
            }
            return output;
        }

        CppSymbol createIndentifier(TypeIdentifier s) {
            return new CppSymbol(s.ident.toString.idup, CppSymbol.Kind.Identifier);
        }

        CppNode createTypeBasic(TypeBasic type) {
            auto getEncoding = (TypeBasic t) {
                final switch (t.ty) {
                    case Tvoid:        return "v";
                    case Tint8:        return "a";
                    case Tuns8:        return "h";
                    case Tint16:       return "s";
                    case Tuns16:       return "t";
                    case Tint32:       return "i";
                    case Tuns32:       return "j";
                    case Tfloat32:     return "f";
                    case Tint64:       return Target.c_longsize == 8 ? "l" : "x";
                    case Tuns64:       return Target.c_longsize == 8 ? "m" : "y";
                    case Tint128:      return "n";
                    case Tuns128:      return "o";
                    case Tfloat64:     return "d";
                    case Tfloat80:     return Target.realislongdouble ? "e" : "g";
                    case Tbool:        return "b";
                    case Tchar:        return "c";
                    case Twchar:       return "t"; // unsigned short
                    case Tdchar:       return "w"; // wchar_t (UTF-32)
                    case Timaginary32: return "Gf";
                    case Timaginary64: return "Gd";
                    case Timaginary80: return "Ge";
                    case Tcomplex32:   return "Cf";
                    case Tcomplex64:   return "Cd";
                    case Tcomplex80:   return "Ce";
                }
            };
            return adaptConstness(type, new CppSymbol(getEncoding(type), CppSymbol.Kind.Basic));
        }
    }

    /*
     * Follows Itanium C++ ABI 1.86
     */
    extern (C++) final class CppMangleVisitor : Visitor
    {
        alias visit = super.visit;
        Objects components;
        OutBuffer buf;
        bool is_top_level;
        bool components_on;

        void writeBase36(size_t i)
        {
            if (i >= 36)
            {
                writeBase36(i / 36);
                i %= 36;
            }
            if (i < 10)
                buf.writeByte(cast(char)(i + '0'));
            else if (i < 36)
                buf.writeByte(cast(char)(i - 10 + 'A'));
            else
                assert(0);
        }

        bool substitute(RootObject p)
        {
            //printf("substitute %s\n", p ? p.toChars() : null);
            if (components_on)
                for (size_t i = 0; i < components.dim; i++)
                {
                    //printf("    component[%d] = %s\n", i, components[i] ? components[i].toChars() : null);
                    if (p == components[i])
                    {
                        //printf("\tmatch\n");
                        /* Sequence is S_, S0_, .., S9_, SA_, ..., SZ_, S10_, ...
                         */
                        buf.writeByte('S');
                        if (i)
                            writeBase36(i - 1);
                        buf.writeByte('_');
                        return true;
                    }
                }
            return false;
        }

        bool exist(RootObject p)
        {
            //printf("exist %s\n", p ? p.toChars() : null);
            if (components_on)
                for (size_t i = 0; i < components.dim; i++)
                {
                    if (p == components[i])
                    {
                        return true;
                    }
                }
            return false;
        }

        void store(RootObject p)
        {
            //printf("store %s\n", p ? p.toChars() : "null");
            if (components_on)
                components.push(p);
        }

        void source_name(Dsymbol s, bool skipname = false)
        {
            //printf("source_name(%s)\n", s.toChars());
            TemplateInstance ti = s.isTemplateInstance();
            if (ti)
            {
                if (!skipname && !substitute(ti.tempdecl))
                {
                    store(ti.tempdecl);
                    const(char)* name = ti.tempdecl.toAlias().ident.toChars();
                    buf.printf("%d%s", strlen(name), name);
                }
                buf.writeByte('I');
                bool is_var_arg = false;
                for (size_t i = 0; i < ti.tiargs.dim; i++)
                {
                    RootObject o = cast(RootObject)(*ti.tiargs)[i];
                    TemplateParameter tp = null;
                    TemplateValueParameter tv = null;
                    TemplateTupleParameter tt = null;
                    if (!is_var_arg)
                    {
                        TemplateDeclaration td = ti.tempdecl.isTemplateDeclaration();
                        assert(td);
                        tp = (*td.parameters)[i];
                        tv = tp.isTemplateValueParameter();
                        tt = tp.isTemplateTupleParameter();
                    }
                    /*
                     *           <template-arg> ::= <type>            # type or template
                     *                          ::= <expr-primary>   # simple expressions
                     */
                    if (tt)
                    {
                        buf.writeByte('I');
                        is_var_arg = true;
                        tp = null;
                    }
                    if (tv)
                    {
                        // <expr-primary> ::= L <type> <value number> E                   # integer literal
                        if (tv.valType.isintegral())
                        {
                            Expression e = isExpression(o);
                            assert(e);
                            buf.writeByte('L');
                            tv.valType.accept(this);
                            if (tv.valType.isunsigned())
                            {
                                buf.printf("%llu", e.toUInteger());
                            }
                            else
                            {
                                sinteger_t val = e.toInteger();
                                if (val < 0)
                                {
                                    val = -val;
                                    buf.writeByte('n');
                                }
                                buf.printf("%lld", val);
                            }
                            buf.writeByte('E');
                        }
                        else
                        {
                            s.error("Internal Compiler Error: C++ %s template value parameter is not supported", tv.valType.toChars());
                            fatal();
                        }
                    }
                    else if (!tp || tp.isTemplateTypeParameter())
                    {
                        Type t = isType(o);
                        assert(t);
                        t.accept(this);
                    }
                    else if (tp.isTemplateAliasParameter())
                    {
                        Dsymbol d = isDsymbol(o);
                        Expression e = isExpression(o);
                        if (!d && !e)
                        {
                            s.error("Internal Compiler Error: %s is unsupported parameter for C++ template: (%s)", o.toChars());
                            fatal();
                        }
                        if (d && d.isFuncDeclaration())
                        {
                            bool is_nested = d.toParent() && !d.toParent().isModule() && (cast(TypeFunction)d.isFuncDeclaration().type).linkage == LINKcpp;
                            if (is_nested)
                                buf.writeByte('X');
                            buf.writeByte('L');
                            mangle_function(d.isFuncDeclaration());
                            buf.writeByte('E');
                            if (is_nested)
                                buf.writeByte('E');
                        }
                        else if (e && e.op == TOKvar && (cast(VarExp)e).var.isVarDeclaration())
                        {
                            VarDeclaration vd = (cast(VarExp)e).var.isVarDeclaration();
                            buf.writeByte('L');
                            mangle_variable(vd, true);
                            buf.writeByte('E');
                        }
                        else if (d && d.isTemplateDeclaration() && d.isTemplateDeclaration().onemember)
                        {
                            if (!substitute(d))
                            {
                                cpp_mangle_name(d, false);
                            }
                        }
                        else
                        {
                            s.error("Internal Compiler Error: %s is unsupported parameter for C++ template", o.toChars());
                            fatal();
                        }
                    }
                    else
                    {
                        s.error("Internal Compiler Error: C++ templates support only integral value, type parameters, alias templates and alias function parameters");
                        fatal();
                    }
                }
                if (is_var_arg)
                {
                    buf.writeByte('E');
                }
                buf.writeByte('E');
                return;
            }
            else
            {
                const(char)* name = s.ident.toChars();
                buf.printf("%d%s", strlen(name), name);
            }
        }

        void prefix_name(Dsymbol s)
        {
            //printf("prefix_name(%s)\n", s.toChars());
            if (!substitute(s))
            {
                Dsymbol p = s.toParent();
                if (p && p.isTemplateInstance())
                {
                    s = p;
                    if (exist(p.isTemplateInstance().tempdecl))
                    {
                        p = null;
                    }
                    else
                    {
                        p = p.toParent();
                    }
                }
                if (p && !p.isModule())
                {
                    if (p.ident == Id.std && is_initial_qualifier(p))
                        buf.writestring("St");
                    else
                        prefix_name(p);
                }
                if (!(s.ident == Id.std && is_initial_qualifier(s)))
                    store(s);
                source_name(s);
            }
        }

        /* Is s the initial qualifier?
         */
        bool is_initial_qualifier(Dsymbol s)
        {
            Dsymbol p = s.toParent();
            if (p && p.isTemplateInstance())
            {
                if (exist(p.isTemplateInstance().tempdecl))
                {
                    return true;
                }
                p = p.toParent();
            }
            return !p || p.isModule();
        }

        void cpp_mangle_name(Dsymbol s, bool qualified)
        {
            //printf("cpp_mangle_name(%s, %d)\n", s.toChars(), qualified);
            Dsymbol p = s.toParent();
            Dsymbol se = s;
            bool dont_write_prefix = false;
            if (p && p.isTemplateInstance())
            {
                se = p;
                if (exist(p.isTemplateInstance().tempdecl))
                    dont_write_prefix = true;
                p = p.toParent();
            }
            if (p && !p.isModule())
            {
                /* The N..E is not required if:
                 * 1. the parent is 'std'
                 * 2. 'std' is the initial qualifier
                 * 3. there is no CV-qualifier or a ref-qualifier for a member function
                 * ABI 5.1.8
                 */
                if (p.ident == Id.std && is_initial_qualifier(p) && !qualified)
                {
                    if (s.ident == Id.allocator)
                    {
                        buf.writestring("Sa"); // "Sa" is short for ::std::allocator
                        source_name(se, true);
                    }
                    else if (s.ident == Id.basic_string)
                    {
                        components_on = false; // turn off substitutions
                        buf.writestring("Sb"); // "Sb" is short for ::std::basic_string
                        size_t off = buf.offset;
                        source_name(se, true);
                        components_on = true;
                        // Replace ::std::basic_string < char, ::std::char_traits<char>, ::std::allocator<char> >
                        // with Ss
                        //printf("xx: '%.*s'\n", (int)(buf.offset - off), buf.data + off);
                        if (buf.offset - off >= 26 && memcmp(buf.data + off, "IcSt11char_traitsIcESaIcEE".ptr, 26) == 0)
                        {
                            buf.remove(off - 2, 28);
                            buf.insert(off - 2, "Ss");
                            return;
                        }
                        buf.setsize(off);
                        source_name(se, true);
                    }
                    else if (s.ident == Id.basic_istream || s.ident == Id.basic_ostream || s.ident == Id.basic_iostream)
                    {
                        /* Replace
                         * ::std::basic_istream<char,  std::char_traits<char> > with Si
                         * ::std::basic_ostream<char,  std::char_traits<char> > with So
                         * ::std::basic_iostream<char, std::char_traits<char> > with Sd
                         */
                        size_t off = buf.offset;
                        components_on = false; // turn off substitutions
                        source_name(se, true);
                        components_on = true;
                        //printf("xx: '%.*s'\n", (int)(buf.offset - off), buf.data + off);
                        if (buf.offset - off >= 21 && memcmp(buf.data + off, "IcSt11char_traitsIcEE".ptr, 21) == 0)
                        {
                            buf.remove(off, 21);
                            char[2] mbuf;
                            mbuf[0] = 'S';
                            mbuf[1] = 'i';
                            if (s.ident == Id.basic_ostream)
                                mbuf[1] = 'o';
                            else if (s.ident == Id.basic_iostream)
                                mbuf[1] = 'd';
                            buf.insert(off, mbuf[]);
                            return;
                        }
                        buf.setsize(off);
                        buf.writestring("St");
                        source_name(se);
                    }
                    else
                    {
                        buf.writestring("St");
                        source_name(se);
                    }
                }
                else
                {
                    buf.writeByte('N');
                    if (!dont_write_prefix)
                        prefix_name(p);
                    source_name(se);
                    buf.writeByte('E');
                }
            }
            else
                source_name(se);
            store(s);
        }

        void mangle_variable(VarDeclaration d, bool is_temp_arg_ref)
        {
            if (!(d.storage_class & (STCextern | STCgshared)))
            {
                d.error("Internal Compiler Error: C++ static non- __gshared non-extern variables not supported");
                fatal();
            }
            Dsymbol p = d.toParent();
            if (p && !p.isModule()) //for example: char Namespace1::beta[6] should be mangled as "_ZN10Namespace14betaE"
            {
                buf.writestring("_ZN");
                prefix_name(p);
                source_name(d);
                buf.writeByte('E');
            }
            else //char beta[6] should mangle as "beta"
            {
                if (!is_temp_arg_ref)
                {
                    buf.writestring(d.ident.toChars());
                }
                else
                {
                    buf.writestring("_Z");
                    source_name(d);
                }
            }
        }

        void mangle_function(FuncDeclaration d)
        {
            //printf("mangle_function(%s)\n", d.toChars());
            /*
             * <mangled-name> ::= _Z <encoding>
             * <encoding> ::= <function name> <bare-function-type>
             *         ::= <data name>
             *         ::= <special-name>
             */
            TypeFunction tf = cast(TypeFunction)d.type;
            buf.writestring("_Z");
            Dsymbol p = d.toParent();
            TemplateDeclaration ftd = getFuncTemplateDecl(d);

            if (p && !p.isModule() && tf.linkage == LINKcpp && !ftd)
            {
                buf.writeByte('N');
                if (d.type.isConst())
                    buf.writeByte('K');
                prefix_name(p);
                // See ABI 5.1.8 Compression
                // Replace ::std::allocator with Sa
                if (buf.offset >= 17 && memcmp(buf.data, "_ZN3std9allocator".ptr, 17) == 0)
                {
                    buf.remove(3, 14);
                    buf.insert(3, "Sa");
                }
                // Replace ::std::basic_string with Sb
                if (buf.offset >= 21 && memcmp(buf.data, "_ZN3std12basic_string".ptr, 21) == 0)
                {
                    buf.remove(3, 18);
                    buf.insert(3, "Sb");
                }
                // Replace ::std with St
                if (buf.offset >= 7 && memcmp(buf.data, "_ZN3std".ptr, 7) == 0)
                {
                    buf.remove(3, 4);
                    buf.insert(3, "St");
                }
                if (buf.offset >= 8 && memcmp(buf.data, "_ZNK3std".ptr, 8) == 0)
                {
                    buf.remove(4, 4);
                    buf.insert(4, "St");
                }
                if (d.isDtorDeclaration())
                {
                    buf.writestring("D1");
                }
                else
                {
                    source_name(d);
                }
                buf.writeByte('E');
            }
            else if (ftd)
            {
                source_name(p);
                this.is_top_level = true;
                tf.nextOf().accept(this);
                this.is_top_level = false;
            }
            else
            {
                source_name(d);
            }
            if (tf.linkage == LINKcpp) //Template args accept extern "C" symbols with special mangling
            {
                assert(tf.ty == Tfunction);
                argsCppMangle(tf.parameters, tf.varargs);
            }
        }

        void argsCppMangle(Parameters* parameters, int varargs)
        {
            int paramsCppMangleDg(size_t n, Parameter fparam)
            {
                Type t = fparam.type.merge2();
                if (fparam.storageClass & (STCout | STCref))
                    t = t.referenceTo();
                else if (fparam.storageClass & STClazy)
                {
                    // Mangle as delegate
                    Type td = new TypeFunction(null, t, 0, LINKd);
                    td = new TypeDelegate(td);
                    t = t.merge();
                }
                if (t.ty == Tsarray)
                {
                    // Mangle static arrays as pointers
                    t.error(Loc(), "Internal Compiler Error: unable to pass static array to extern(C++) function.");
                    t.error(Loc(), "Use pointer instead.");
                    fatal();
                    //t = t.nextOf().pointerTo();
                }
                /* If it is a basic, enum or struct type,
                 * then don't mark it const
                 */
                this.is_top_level = true;
                if ((t.ty == Tenum || t.ty == Tstruct || t.ty == Tpointer || t.isTypeBasic()) && t.isConst())
                    t.mutableOf().accept(this);
                else
                    t.accept(this);
                this.is_top_level = false;
                return 0;
            }

            if (parameters)
                Parameter._foreach(parameters, &paramsCppMangleDg);
            if (varargs)
                buf.writestring("z");
            else if (!parameters || !parameters.dim)
                buf.writeByte('v'); // encode ( ) parameters
        }

    public:
        extern (D) this()
        {
            this.components_on = true;
        }

        const(char)* mangleOf(Dsymbol s)
        {
            VarDeclaration vd = s.isVarDeclaration();
            FuncDeclaration fd = s.isFuncDeclaration();
            if (vd)
            {
                mangle_variable(vd, false);
            }
            else if (fd)
            {
                mangle_function(fd);
            }
            else
            {
                assert(0);
            }
            Target.prefixName(&buf, LINKcpp);
            return buf.extractString();
        }

        override void visit(Type t)
        {
            if (t.isImmutable() || t.isShared())
            {
                t.error(Loc(), "Internal Compiler Error: shared or immutable types can not be mapped to C++ (%s)", t.toChars());
            }
            else
            {
                t.error(Loc(), "Internal Compiler Error: unsupported type %s\n", t.toChars());
            }
            fatal(); //Fatal, because this error should be handled in frontend
        }

        override void visit(TypeBasic t)
        {
            /* ABI spec says:
             * v        void
             * w        wchar_t
             * b        bool
             * c        char
             * a        signed char
             * h        unsigned char
             * s        short
             * t        unsigned short
             * i        int
             * j        unsigned int
             * l        long
             * m        unsigned long
             * x        long long, __int64
             * y        unsigned long long, __int64
             * n        __int128
             * o        unsigned __int128
             * f        float
             * d        double
             * e        long double, __float80
             * g        __float128
             * z        ellipsis
             * u <source-name>  # vendor extended type
             */
            char c;
            char p = 0;
            switch (t.ty)
            {
            case Tvoid:
                c = 'v';
                break;
            case Tint8:
                c = 'a';
                break;
            case Tuns8:
                c = 'h';
                break;
            case Tint16:
                c = 's';
                break;
            case Tuns16:
                c = 't';
                break;
            case Tint32:
                c = 'i';
                break;
            case Tuns32:
                c = 'j';
                break;
            case Tfloat32:
                c = 'f';
                break;
            case Tint64:
                c = (Target.c_longsize == 8 ? 'l' : 'x');
                break;
            case Tuns64:
                c = (Target.c_longsize == 8 ? 'm' : 'y');
                break;
            case Tint128:
                c = 'n';
                break;
            case Tuns128:
                c = 'o';
                break;
            case Tfloat64:
                c = 'd';
                break;
            case Tfloat80:
                c = Target.realislongdouble ? 'e' : 'g';
                break;
            case Tbool:
                c = 'b';
                break;
            case Tchar:
                c = 'c';
                break;
            case Twchar:
                c = 't';
                break;
                // unsigned short
            case Tdchar:
                c = 'w';
                break;
                // wchar_t (UTF-32)
            case Timaginary32:
                p = 'G';
                c = 'f';
                break;
            case Timaginary64:
                p = 'G';
                c = 'd';
                break;
            case Timaginary80:
                p = 'G';
                c = 'e';
                break;
            case Tcomplex32:
                p = 'C';
                c = 'f';
                break;
            case Tcomplex64:
                p = 'C';
                c = 'd';
                break;
            case Tcomplex80:
                p = 'C';
                c = 'e';
                break;
            default:
                visit(cast(Type)t);
                return;
            }
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (p || t.isConst())
            {
                if (substitute(t))
                {
                    return;
                }
                else
                {
                    store(t);
                }
            }
            if (t.isConst())
                buf.writeByte('K');
            if (p)
                buf.writeByte(p);
            buf.writeByte(c);
        }

        override void visit(TypeVector t)
        {
            is_top_level = false;
            if (substitute(t))
                return;
            store(t);
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst())
                buf.writeByte('K');
            assert(t.basetype && t.basetype.ty == Tsarray);
            assert((cast(TypeSArray)t.basetype).dim);
            //buf.printf("Dv%llu_", ((TypeSArray *)t.basetype).dim.toInteger());// -- Gnu ABI v.4
            buf.writestring("U8__vector"); //-- Gnu ABI v.3
            t.basetype.nextOf().accept(this);
        }

        override void visit(TypeSArray t)
        {
            is_top_level = false;
            if (!substitute(t))
                store(t);
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst())
                buf.writeByte('K');
            buf.printf("A%llu_", t.dim ? t.dim.toInteger() : 0);
            t.next.accept(this);
        }

        override void visit(TypeDArray t)
        {
            visit(cast(Type)t);
        }

        override void visit(TypeAArray t)
        {
            visit(cast(Type)t);
        }

        override void visit(TypePointer t)
        {
            is_top_level = false;
            if (substitute(t))
                return;
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst())
                buf.writeByte('K');
            buf.writeByte('P');
            t.next.accept(this);
            store(t);
        }

        override void visit(TypeReference t)
        {
            is_top_level = false;
            if (substitute(t))
                return;
            buf.writeByte('R');
            t.next.accept(this);
            store(t);
        }

        override void visit(TypeFunction t)
        {
            is_top_level = false;
            /*
             *  <function-type> ::= F [Y] <bare-function-type> E
             *  <bare-function-type> ::= <signature type>+
             *  # types are possible return type, then parameter types
             */
            /* ABI says:
                "The type of a non-static member function is considered to be different,
                for the purposes of substitution, from the type of a namespace-scope or
                static member function whose type appears similar. The types of two
                non-static member functions are considered to be different, for the
                purposes of substitution, if the functions are members of different
                classes. In other words, for the purposes of substitution, the class of
                which the function is a member is considered part of the type of
                function."

                BUG: Right now, types of functions are never merged, so our simplistic
                component matcher always finds them to be different.
                We should use Type.equals on these, and use different
                TypeFunctions for non-static member functions, and non-static
                member functions of different classes.
             */
            if (substitute(t))
                return;
            buf.writeByte('F');
            if (t.linkage == LINKc)
                buf.writeByte('Y');
            Type tn = t.next;
            if (t.isref)
                tn = tn.referenceTo();
            tn.accept(this);
            argsCppMangle(t.parameters, t.varargs);
            buf.writeByte('E');
            store(t);
        }

        override void visit(TypeDelegate t)
        {
            visit(cast(Type)t);
        }

        override void visit(TypeStruct t)
        {
            const id = t.sym.ident;
            //printf("struct id = '%s'\n", id.toChars());
            char c;
            if (id == Id.__c_long)
                c = 'l';
            else if (id == Id.__c_ulong)
                c = 'm';
            else
                c = 0;
            if (c)
            {
                if (t.isImmutable() || t.isShared())
                {
                    visit(cast(Type)t);
                }
                if (t.isConst())
                {
                    if (substitute(t))
                    {
                        return;
                    }
                    else
                    {
                        store(t);
                    }
                }
                if (t.isConst())
                    buf.writeByte('K');
                buf.writeByte(c);
                return;
            }
            is_top_level = false;
            if (substitute(t))
                return;
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst())
                buf.writeByte('K');
            if (!substitute(t.sym))
            {
                cpp_mangle_name(t.sym, t.isConst());
            }
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst())
                store(t);
        }

        override void visit(TypeEnum t)
        {
            is_top_level = false;
            if (substitute(t))
                return;
            if (t.isConst())
                buf.writeByte('K');
            if (!substitute(t.sym))
            {
                cpp_mangle_name(t.sym, t.isConst());
            }
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst())
                store(t);
        }

        override void visit(TypeClass t)
        {
            if (substitute(t))
                return;
            if (t.isImmutable() || t.isShared())
            {
                visit(cast(Type)t);
            }
            if (t.isConst() && !is_top_level)
                buf.writeByte('K');
            is_top_level = false;
            buf.writeByte('P');
            if (t.isConst())
                buf.writeByte('K');
            if (!substitute(t.sym))
            {
                cpp_mangle_name(t.sym, t.isConst());
            }
            if (t.isConst())
                store(null);
            store(t);
        }

        final const(char)* mangle_typeinfo(Dsymbol s)
        {
            buf.writestring("_ZTI");
            cpp_mangle_name(s, false);
            return buf.extractString();
        }
    }

    //-------------------------------------------------------------------------
    // New implementation.
    //-------------------------------------------------------------------------

    const(char)* createDeclaration(Declaration decl) {
        CppSymbol node = ScopeHierarchy.create(decl);
//         char[] buffer;
//         print(node, buffer, 2, "");
//         buffer ~= '\0';
//         printf("ToString: %s\n", buffer.ptr);
        scope Context output = new Context();
        output.mangleAsCpp = decl.isConst || isNested(node) || decl.isFuncDeclaration;
        if(output.mangleAsCpp) output.append("_Z");
        node.mangle(output);
        auto mangledString = output.finish();
        printf("%s\n", mangledString);
        return mangledString;
    }

    extern (C++) const(char)* toCppMangle(Dsymbol s)
    {
        if(s.isVarDeclaration || s.isFuncDeclaration)
            return createDeclaration(s.isDeclaration);
        error(Loc(), "Internal Compiler Error: unsupported type\n");
        fatal();
        assert(0);
    }

    extern (C++) const(char)* cppTypeInfoMangle(Dsymbol s)
    {
        //printf("cppTypeInfoMangle(%s)\n", s.toChars());
        scope CppMangleVisitor v = new CppMangleVisitor();
        return v.mangle_typeinfo(s);
    }
}
else static if (TARGET_WINDOS)
{
    // Windows DMC and Microsoft Visual C++ mangling
    enum VC_SAVED_TYPE_CNT = 10u;
    enum VC_SAVED_IDENT_CNT = 10u;

    extern (C++) final class VisualCPPMangler : Visitor
    {
        alias visit = super.visit;
        const(char)*[VC_SAVED_IDENT_CNT] saved_idents;
        Type[VC_SAVED_TYPE_CNT] saved_types;

        // IS_NOT_TOP_TYPE: when we mangling one argument, we can call visit several times (for base types of arg type)
        // but we must save only arg type:
        // For example: if we have an int** argument, we should save "int**" but visit will be called for "int**", "int*", "int"
        // This flag is set up by the visit(NextType, ) function  and should be reset when the arg type output is finished.
        // MANGLE_RETURN_TYPE: return type shouldn't be saved and substituted in arguments
        // IGNORE_CONST: in some cases we should ignore CV-modifiers.

        enum Flags : int
        {
            IS_NOT_TOP_TYPE = 0x1,
            MANGLE_RETURN_TYPE = 0x2,
            IGNORE_CONST = 0x4,
            IS_DMC = 0x8,
        }

        alias IS_NOT_TOP_TYPE = Flags.IS_NOT_TOP_TYPE;
        alias MANGLE_RETURN_TYPE = Flags.MANGLE_RETURN_TYPE;
        alias IGNORE_CONST = Flags.IGNORE_CONST;
        alias IS_DMC = Flags.IS_DMC;

        int flags;
        OutBuffer buf;

        extern (D) this(VisualCPPMangler rvl)
        {
            flags |= (rvl.flags & IS_DMC);
            memcpy(&saved_idents, &rvl.saved_idents, (const(char)*).sizeof * VC_SAVED_IDENT_CNT);
            memcpy(&saved_types, &rvl.saved_types, Type.sizeof * VC_SAVED_TYPE_CNT);
        }

    public:
        extern (D) this(bool isdmc)
        {
            if (isdmc)
            {
                flags |= IS_DMC;
            }
            memset(&saved_idents, 0, (const(char)*).sizeof * VC_SAVED_IDENT_CNT);
            memset(&saved_types, 0, Type.sizeof * VC_SAVED_TYPE_CNT);
        }

        override void visit(Type type)
        {
            if (type.isImmutable() || type.isShared())
            {
                type.error(Loc(), "Internal Compiler Error: shared or immutable types can not be mapped to C++ (%s)", type.toChars());
            }
            else
            {
                type.error(Loc(), "Internal Compiler Error: unsupported type %s\n", type.toChars());
            }
            fatal(); //Fatal, because this error should be handled in frontend
        }

        override void visit(TypeBasic type)
        {
            //printf("visit(TypeBasic); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
            if (type.isImmutable() || type.isShared())
            {
                visit(cast(Type)type);
                return;
            }
            if (type.isConst() && ((flags & IS_NOT_TOP_TYPE) || (flags & IS_DMC)))
            {
                if (checkTypeSaved(type))
                    return;
            }
            if ((type.ty == Tbool) && checkTypeSaved(type)) // try to replace long name with number
            {
                return;
            }
            if (!(flags & IS_DMC))
            {
                switch (type.ty)
                {
                case Tint64:
                case Tuns64:
                case Tint128:
                case Tuns128:
                case Tfloat80:
                case Twchar:
                    if (checkTypeSaved(type))
                        return;
                    break;

                default:
                    break;
                }
            }
            mangleModifier(type);
            switch (type.ty)
            {
            case Tvoid:
                buf.writeByte('X');
                break;
            case Tint8:
                buf.writeByte('C');
                break;
            case Tuns8:
                buf.writeByte('E');
                break;
            case Tint16:
                buf.writeByte('F');
                break;
            case Tuns16:
                buf.writeByte('G');
                break;
            case Tint32:
                buf.writeByte('H');
                break;
            case Tuns32:
                buf.writeByte('I');
                break;
            case Tfloat32:
                buf.writeByte('M');
                break;
            case Tint64:
                buf.writestring("_J");
                break;
            case Tuns64:
                buf.writestring("_K");
                break;
            case Tint128:
                buf.writestring("_L");
                break;
            case Tuns128:
                buf.writestring("_M");
                break;
            case Tfloat64:
                buf.writeByte('N');
                break;
            case Tbool:
                buf.writestring("_N");
                break;
            case Tchar:
                buf.writeByte('D');
                break;
            case Tdchar:
                buf.writeByte('I');
                break;
                // unsigned int
            case Tfloat80:
                if (flags & IS_DMC)
                    buf.writestring("_Z"); // DigitalMars long double
                else
                    buf.writestring("_T"); // Intel long double
                break;
            case Twchar:
                if (flags & IS_DMC)
                    buf.writestring("_Y"); // DigitalMars wchar_t
                else
                    buf.writestring("_W"); // Visual C++ wchar_t
                break;
            default:
                visit(cast(Type)type);
                return;
            }
            flags &= ~IS_NOT_TOP_TYPE;
            flags &= ~IGNORE_CONST;
        }

        override void visit(TypeVector type)
        {
            //printf("visit(TypeVector); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
            if (checkTypeSaved(type))
                return;
            buf.writestring("T__m128@@"); // may be better as __m128i or __m128d?
            flags &= ~IS_NOT_TOP_TYPE;
            flags &= ~IGNORE_CONST;
        }

        override void visit(TypeSArray type)
        {
            // This method can be called only for static variable type mangling.
            //printf("visit(TypeSArray); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
            if (checkTypeSaved(type))
                return;
            // first dimension always mangled as const pointer
            if (flags & IS_DMC)
                buf.writeByte('Q');
            else
                buf.writeByte('P');
            flags |= IS_NOT_TOP_TYPE;
            assert(type.next);
            if (type.next.ty == Tsarray)
            {
                mangleArray(cast(TypeSArray)type.next);
            }
            else
            {
                type.next.accept(this);
            }
        }

        // attention: D int[1][2]* arr mapped to C++ int arr[][2][1]; (because it's more typical situation)
        // There is not way to map int C++ (*arr)[2][1] to D
        override void visit(TypePointer type)
        {
            //printf("visit(TypePointer); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
            if (type.isImmutable() || type.isShared())
            {
                visit(cast(Type)type);
                return;
            }
            assert(type.next);
            if (type.next.ty == Tfunction)
            {
                const(char)* arg = mangleFunctionType(cast(TypeFunction)type.next); // compute args before checking to save; args should be saved before function type
                // If we've mangled this function early, previous call is meaningless.
                // However we should do it before checking to save types of function arguments before function type saving.
                // If this function was already mangled, types of all it arguments are save too, thus previous can't save
                // anything if function is saved.
                if (checkTypeSaved(type))
                    return;
                if (type.isConst())
                    buf.writeByte('Q'); // const
                else
                    buf.writeByte('P'); // mutable
                buf.writeByte('6'); // pointer to a function
                buf.writestring(arg);
                flags &= ~IS_NOT_TOP_TYPE;
                flags &= ~IGNORE_CONST;
                return;
            }
            else if (type.next.ty == Tsarray)
            {
                if (checkTypeSaved(type))
                    return;
                mangleModifier(type);
                if (type.isConst() || !(flags & IS_DMC))
                    buf.writeByte('Q'); // const
                else
                    buf.writeByte('P'); // mutable
                if (global.params.is64bit)
                    buf.writeByte('E');
                flags |= IS_NOT_TOP_TYPE;
                mangleArray(cast(TypeSArray)type.next);
                return;
            }
            else
            {
                if (checkTypeSaved(type))
                    return;
                mangleModifier(type);
                if (type.isConst())
                {
                    buf.writeByte('Q'); // const
                }
                else
                {
                    buf.writeByte('P'); // mutable
                }
                if (global.params.is64bit)
                    buf.writeByte('E');
                flags |= IS_NOT_TOP_TYPE;
                type.next.accept(this);
            }
        }

        override void visit(TypeReference type)
        {
            //printf("visit(TypeReference); type = %s\n", type.toChars());
            if (checkTypeSaved(type))
                return;
            if (type.isImmutable() || type.isShared())
            {
                visit(cast(Type)type);
                return;
            }
            buf.writeByte('A'); // mutable
            if (global.params.is64bit)
                buf.writeByte('E');
            flags |= IS_NOT_TOP_TYPE;
            assert(type.next);
            if (type.next.ty == Tsarray)
            {
                mangleArray(cast(TypeSArray)type.next);
            }
            else
            {
                type.next.accept(this);
            }
        }

        override void visit(TypeFunction type)
        {
            const(char)* arg = mangleFunctionType(type);
            if ((flags & IS_DMC))
            {
                if (checkTypeSaved(type))
                    return;
            }
            else
            {
                buf.writestring("$$A6");
            }
            buf.writestring(arg);
            flags &= ~(IS_NOT_TOP_TYPE | IGNORE_CONST);
        }

        override void visit(TypeStruct type)
        {
            const id = type.sym.ident;
            char c;
            if (id == Id.__c_long_double)
                c = 'O'; // VC++ long double
            else if (id == Id.__c_long)
                c = 'J'; // VC++ long
            else if (id == Id.__c_ulong)
                c = 'K'; // VC++ unsigned long
            else
                c = 0;
            if (c)
            {
                if (type.isImmutable() || type.isShared())
                {
                    visit(cast(Type)type);
                    return;
                }
                if (type.isConst() && ((flags & IS_NOT_TOP_TYPE) || (flags & IS_DMC)))
                {
                    if (checkTypeSaved(type))
                        return;
                }
                mangleModifier(type);
                buf.writeByte(c);
            }
            else
            {
                if (checkTypeSaved(type))
                    return;
                //printf("visit(TypeStruct); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
                mangleModifier(type);
                if (type.sym.isUnionDeclaration())
                    buf.writeByte('T');
                else
                    buf.writeByte('U');
                mangleIdent(type.sym);
            }
            flags &= ~IS_NOT_TOP_TYPE;
            flags &= ~IGNORE_CONST;
        }

        override void visit(TypeEnum type)
        {
            //printf("visit(TypeEnum); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
            if (checkTypeSaved(type))
                return;
            mangleModifier(type);
            buf.writeByte('W');
            switch (type.sym.memtype.ty)
            {
            case Tchar:
            case Tint8:
                buf.writeByte('0');
                break;
            case Tuns8:
                buf.writeByte('1');
                break;
            case Tint16:
                buf.writeByte('2');
                break;
            case Tuns16:
                buf.writeByte('3');
                break;
            case Tint32:
                buf.writeByte('4');
                break;
            case Tuns32:
                buf.writeByte('5');
                break;
            case Tint64:
                buf.writeByte('6');
                break;
            case Tuns64:
                buf.writeByte('7');
                break;
            default:
                visit(cast(Type)type);
                break;
            }
            mangleIdent(type.sym);
            flags &= ~IS_NOT_TOP_TYPE;
            flags &= ~IGNORE_CONST;
        }

        // D class mangled as pointer to C++ class
        // const(Object) mangled as Object const* const
        override void visit(TypeClass type)
        {
            //printf("visit(TypeClass); is_not_top_type = %d\n", (int)(flags & IS_NOT_TOP_TYPE));
            if (checkTypeSaved(type))
                return;
            if (flags & IS_NOT_TOP_TYPE)
                mangleModifier(type);
            if (type.isConst())
                buf.writeByte('Q');
            else
                buf.writeByte('P');
            if (global.params.is64bit)
                buf.writeByte('E');
            flags |= IS_NOT_TOP_TYPE;
            mangleModifier(type);
            buf.writeByte('V');
            mangleIdent(type.sym);
            flags &= ~IS_NOT_TOP_TYPE;
            flags &= ~IGNORE_CONST;
        }

        const(char)* mangleOf(Dsymbol s)
        {
            VarDeclaration vd = s.isVarDeclaration();
            FuncDeclaration fd = s.isFuncDeclaration();
            if (vd)
            {
                mangleVariable(vd);
            }
            else if (fd)
            {
                mangleFunction(fd);
            }
            else
            {
                assert(0);
            }
            return buf.extractString();
        }

    private:
        void mangleFunction(FuncDeclaration d)
        {
            // <function mangle> ? <qualified name> <flags> <return type> <arg list>
            assert(d);
            buf.writeByte('?');
            mangleIdent(d);
            if (d.needThis()) // <flags> ::= <virtual/protection flag> <const/volatile flag> <calling convention flag>
            {
                // Pivate methods always non-virtual in D and it should be mangled as non-virtual in C++
                //printf("%s: isVirtualMethod = %d, isVirtual = %d, vtblIndex = %d, interfaceVirtual = %p\n",
                    //d.toChars(), d.isVirtualMethod(), d.isVirtual(), cast(int)d.vtblIndex, d.interfaceVirtual);
                if (d.isVirtual() && (d.vtblIndex != -1 || d.interfaceVirtual || d.overrideInterface()))
                {
                    switch (d.protection.kind)
                    {
                    case PROTprivate:
                        buf.writeByte('E');
                        break;
                    case PROTprotected:
                        buf.writeByte('M');
                        break;
                    default:
                        buf.writeByte('U');
                        break;
                    }
                }
                else
                {
                    switch (d.protection.kind)
                    {
                    case PROTprivate:
                        buf.writeByte('A');
                        break;
                    case PROTprotected:
                        buf.writeByte('I');
                        break;
                    default:
                        buf.writeByte('Q');
                        break;
                    }
                }
                if (global.params.is64bit)
                    buf.writeByte('E');
                if (d.type.isConst())
                {
                    buf.writeByte('B');
                }
                else
                {
                    buf.writeByte('A');
                }
            }
            else if (d.isMember2()) // static function
            {
                // <flags> ::= <virtual/protection flag> <calling convention flag>
                switch (d.protection.kind)
                {
                case PROTprivate:
                    buf.writeByte('C');
                    break;
                case PROTprotected:
                    buf.writeByte('K');
                    break;
                default:
                    buf.writeByte('S');
                    break;
                }
            }
            else // top-level function
            {
                // <flags> ::= Y <calling convention flag>
                buf.writeByte('Y');
            }
            const(char)* args = mangleFunctionType(cast(TypeFunction)d.type, d.needThis(), d.isCtorDeclaration() || d.isDtorDeclaration());
            buf.writestring(args);
        }

        void mangleVariable(VarDeclaration d)
        {
            // <static variable mangle> ::= ? <qualified name> <protection flag> <const/volatile flag> <type>
            assert(d);
            if (!(d.storage_class & (STCextern | STCgshared)))
            {
                d.error("Internal Compiler Error: C++ static non- __gshared non-extern variables not supported");
                fatal();
            }
            buf.writeByte('?');
            mangleIdent(d);
            assert(!d.needThis());
            if (d.parent && d.parent.isModule()) // static member
            {
                buf.writeByte('3');
            }
            else
            {
                switch (d.protection.kind)
                {
                case PROTprivate:
                    buf.writeByte('0');
                    break;
                case PROTprotected:
                    buf.writeByte('1');
                    break;
                default:
                    buf.writeByte('2');
                    break;
                }
            }
            char cv_mod = 0;
            Type t = d.type;
            if (t.isImmutable() || t.isShared())
            {
                visit(t);
                return;
            }
            if (t.isConst())
            {
                cv_mod = 'B'; // const
            }
            else
            {
                cv_mod = 'A'; // mutable
            }
            if (t.ty != Tpointer)
                t = t.mutableOf();
            t.accept(this);
            if ((t.ty == Tpointer || t.ty == Treference || t.ty == Tclass) && global.params.is64bit)
            {
                buf.writeByte('E');
            }
            buf.writeByte(cv_mod);
        }

        void mangleName(Dsymbol sym, bool dont_use_back_reference = false)
        {
            //printf("mangleName('%s')\n", sym.toChars());
            const(char)* name = null;
            bool is_dmc_template = false;
            if (sym.isDtorDeclaration())
            {
                buf.writestring("?1");
                return;
            }
            if (TemplateInstance ti = sym.isTemplateInstance())
            {
                scope VisualCPPMangler tmp = new VisualCPPMangler((flags & IS_DMC) ? true : false);
                tmp.buf.writeByte('?');
                tmp.buf.writeByte('$');
                tmp.buf.writestring(ti.name.toChars());
                tmp.saved_idents[0] = ti.name.toChars();
                tmp.buf.writeByte('@');
                if (flags & IS_DMC)
                {
                    tmp.mangleIdent(sym.parent, true);
                    is_dmc_template = true;
                }
                bool is_var_arg = false;
                for (size_t i = 0; i < ti.tiargs.dim; i++)
                {
                    RootObject o = (*ti.tiargs)[i];
                    TemplateParameter tp = null;
                    TemplateValueParameter tv = null;
                    TemplateTupleParameter tt = null;
                    if (!is_var_arg)
                    {
                        TemplateDeclaration td = ti.tempdecl.isTemplateDeclaration();
                        assert(td);
                        tp = (*td.parameters)[i];
                        tv = tp.isTemplateValueParameter();
                        tt = tp.isTemplateTupleParameter();
                    }
                    if (tt)
                    {
                        is_var_arg = true;
                        tp = null;
                    }
                    if (tv)
                    {
                        if (tv.valType.isintegral())
                        {
                            tmp.buf.writeByte('$');
                            tmp.buf.writeByte('0');
                            Expression e = isExpression(o);
                            assert(e);
                            if (tv.valType.isunsigned())
                            {
                                tmp.mangleNumber(e.toUInteger());
                            }
                            else if (is_dmc_template)
                            {
                                // NOTE: DMC mangles everything based on
                                // unsigned int
                                tmp.mangleNumber(e.toInteger());
                            }
                            else
                            {
                                sinteger_t val = e.toInteger();
                                if (val < 0)
                                {
                                    val = -val;
                                    tmp.buf.writeByte('?');
                                }
                                tmp.mangleNumber(val);
                            }
                        }
                        else
                        {
                            sym.error("Internal Compiler Error: C++ %s template value parameter is not supported", tv.valType.toChars());
                            fatal();
                        }
                    }
                    else if (!tp || tp.isTemplateTypeParameter())
                    {
                        Type t = isType(o);
                        assert(t);
                        t.accept(tmp);
                    }
                    else if (tp.isTemplateAliasParameter())
                    {
                        Dsymbol d = isDsymbol(o);
                        Expression e = isExpression(o);
                        if (!d && !e)
                        {
                            sym.error("Internal Compiler Error: %s is unsupported parameter for C++ template", o.toChars());
                            fatal();
                        }
                        if (d && d.isFuncDeclaration())
                        {
                            tmp.buf.writeByte('$');
                            tmp.buf.writeByte('1');
                            tmp.mangleFunction(d.isFuncDeclaration());
                        }
                        else if (e && e.op == TOKvar && (cast(VarExp)e).var.isVarDeclaration())
                        {
                            tmp.buf.writeByte('$');
                            if (flags & IS_DMC)
                                tmp.buf.writeByte('1');
                            else
                                tmp.buf.writeByte('E');
                            tmp.mangleVariable((cast(VarExp)e).var.isVarDeclaration());
                        }
                        else if (d && d.isTemplateDeclaration() && d.isTemplateDeclaration().onemember)
                        {
                            Dsymbol ds = d.isTemplateDeclaration().onemember;
                            if (flags & IS_DMC)
                            {
                                tmp.buf.writeByte('V');
                            }
                            else
                            {
                                if (ds.isUnionDeclaration())
                                {
                                    tmp.buf.writeByte('T');
                                }
                                else if (ds.isStructDeclaration())
                                {
                                    tmp.buf.writeByte('U');
                                }
                                else if (ds.isClassDeclaration())
                                {
                                    tmp.buf.writeByte('V');
                                }
                                else
                                {
                                    sym.error("Internal Compiler Error: C++ templates support only integral value, type parameters, alias templates and alias function parameters");
                                    fatal();
                                }
                            }
                            tmp.mangleIdent(d);
                        }
                        else
                        {
                            sym.error("Internal Compiler Error: %s is unsupported parameter for C++ template: (%s)", o.toChars());
                            fatal();
                        }
                    }
                    else
                    {
                        sym.error("Internal Compiler Error: C++ templates support only integral value, type parameters, alias templates and alias function parameters");
                        fatal();
                    }
                }
                name = tmp.buf.extractString();
            }
            else
            {
                name = sym.ident.toChars();
            }
            assert(name);
            if (!is_dmc_template)
            {
                if (dont_use_back_reference)
                {
                    saveIdent(name);
                }
                else
                {
                    if (checkAndSaveIdent(name))
                        return;
                }
            }
            buf.writestring(name);
            buf.writeByte('@');
        }

        // returns true if name already saved
        bool checkAndSaveIdent(const(char)* name)
        {
            foreach (i; 0 .. VC_SAVED_IDENT_CNT)
            {
                if (!saved_idents[i]) // no saved same name
                {
                    saved_idents[i] = name;
                    break;
                }
                if (!strcmp(saved_idents[i], name)) // ok, we've found same name. use index instead of name
                {
                    buf.writeByte(i + '0');
                    return true;
                }
            }
            return false;
        }

        void saveIdent(const(char)* name)
        {
            foreach (i; 0 .. VC_SAVED_IDENT_CNT)
            {
                if (!saved_idents[i]) // no saved same name
                {
                    saved_idents[i] = name;
                    break;
                }
                if (!strcmp(saved_idents[i], name)) // ok, we've found same name. use index instead of name
                {
                    return;
                }
            }
        }

        void mangleIdent(Dsymbol sym, bool dont_use_back_reference = false)
        {
            // <qualified name> ::= <sub-name list> @
            // <sub-name list>  ::= <sub-name> <name parts>
            //                  ::= <sub-name>
            // <sub-name> ::= <identifier> @
            //            ::= ?$ <identifier> @ <template args> @
            //            :: <back reference>
            // <back reference> ::= 0-9
            // <template args> ::= <template arg> <template args>
            //                ::= <template arg>
            // <template arg>  ::= <type>
            //                ::= $0<encoded integral number>
            //printf("mangleIdent('%s')\n", sym.toChars());
            Dsymbol p = sym;
            if (p.toParent() && p.toParent().isTemplateInstance())
            {
                p = p.toParent();
            }
            while (p && !p.isModule())
            {
                mangleName(p, dont_use_back_reference);
                p = p.toParent();
                if (p.toParent() && p.toParent().isTemplateInstance())
                {
                    p = p.toParent();
                }
            }
            if (!dont_use_back_reference)
                buf.writeByte('@');
        }

        void mangleNumber(dinteger_t num)
        {
            if (!num) // 0 encoded as "A@"
            {
                buf.writeByte('A');
                buf.writeByte('@');
                return;
            }
            if (num <= 10) // 5 encoded as "4"
            {
                buf.writeByte(cast(char)(num - 1 + '0'));
                return;
            }
            char[17] buff;
            buff[16] = 0;
            size_t i = 16;
            while (num)
            {
                --i;
                buff[i] = num % 16 + 'A';
                num /= 16;
            }
            buf.writestring(&buff[i]);
            buf.writeByte('@');
        }

        bool checkTypeSaved(Type type)
        {
            if (flags & IS_NOT_TOP_TYPE)
                return false;
            if (flags & MANGLE_RETURN_TYPE)
                return false;
            for (uint i = 0; i < VC_SAVED_TYPE_CNT; i++)
            {
                if (!saved_types[i]) // no saved same type
                {
                    saved_types[i] = type;
                    return false;
                }
                if (saved_types[i].equals(type)) // ok, we've found same type. use index instead of type
                {
                    buf.writeByte(i + '0');
                    flags &= ~IS_NOT_TOP_TYPE;
                    flags &= ~IGNORE_CONST;
                    return true;
                }
            }
            return false;
        }

        void mangleModifier(Type type)
        {
            if (flags & IGNORE_CONST)
                return;
            if (type.isImmutable() || type.isShared())
            {
                visit(type);
                return;
            }
            if (type.isConst())
            {
                if (flags & IS_NOT_TOP_TYPE)
                    buf.writeByte('B'); // const
                else if ((flags & IS_DMC) && type.ty != Tpointer)
                    buf.writestring("_O");
            }
            else if (flags & IS_NOT_TOP_TYPE)
                buf.writeByte('A'); // mutable
        }

        void mangleArray(TypeSArray type)
        {
            mangleModifier(type);
            size_t i = 0;
            Type cur = type;
            while (cur && cur.ty == Tsarray)
            {
                i++;
                cur = cur.nextOf();
            }
            buf.writeByte('Y');
            mangleNumber(i); // count of dimensions
            cur = type;
            while (cur && cur.ty == Tsarray) // sizes of dimensions
            {
                TypeSArray sa = cast(TypeSArray)cur;
                mangleNumber(sa.dim ? sa.dim.toInteger() : 0);
                cur = cur.nextOf();
            }
            flags |= IGNORE_CONST;
            cur.accept(this);
        }

        const(char)* mangleFunctionType(TypeFunction type, bool needthis = false, bool noreturn = false)
        {
            scope VisualCPPMangler tmp = new VisualCPPMangler(this);
            // Calling convention
            if (global.params.is64bit) // always Microsoft x64 calling convention
            {
                tmp.buf.writeByte('A');
            }
            else
            {
                switch (type.linkage)
                {
                case LINKc:
                    tmp.buf.writeByte('A');
                    break;
                case LINKcpp:
                    if (needthis && type.varargs != 1)
                        tmp.buf.writeByte('E'); // thiscall
                    else
                        tmp.buf.writeByte('A'); // cdecl
                    break;
                case LINKwindows:
                    tmp.buf.writeByte('G'); // stdcall
                    break;
                case LINKpascal:
                    tmp.buf.writeByte('C');
                    break;
                default:
                    tmp.visit(cast(Type)type);
                    break;
                }
            }
            tmp.flags &= ~IS_NOT_TOP_TYPE;
            if (noreturn)
            {
                tmp.buf.writeByte('@');
            }
            else
            {
                Type rettype = type.next;
                if (type.isref)
                    rettype = rettype.referenceTo();
                flags &= ~IGNORE_CONST;
                if (rettype.ty == Tstruct || rettype.ty == Tenum)
                {
                    const id = rettype.toDsymbol(null).ident;
                    if (id != Id.__c_long_double && id != Id.__c_long && id != Id.__c_ulong)
                    {
                        tmp.buf.writeByte('?');
                        tmp.buf.writeByte('A');
                    }
                }
                tmp.flags |= MANGLE_RETURN_TYPE;
                rettype.accept(tmp);
                tmp.flags &= ~MANGLE_RETURN_TYPE;
            }
            if (!type.parameters || !type.parameters.dim)
            {
                if (type.varargs == 1)
                    tmp.buf.writeByte('Z');
                else
                    tmp.buf.writeByte('X');
            }
            else
            {
                int mangleParameterDg(size_t n, Parameter p)
                {
                    Type t = p.type;
                    if (p.storageClass & (STCout | STCref))
                    {
                        t = t.referenceTo();
                    }
                    else if (p.storageClass & STClazy)
                    {
                        // Mangle as delegate
                        Type td = new TypeFunction(null, t, 0, LINKd);
                        td = new TypeDelegate(td);
                        t = t.merge();
                    }
                    if (t.ty == Tsarray)
                    {
                        t.error(Loc(), "Internal Compiler Error: unable to pass static array to extern(C++) function.");
                        t.error(Loc(), "Use pointer instead.");
                        assert(0);
                    }
                    tmp.flags &= ~IS_NOT_TOP_TYPE;
                    tmp.flags &= ~IGNORE_CONST;
                    t.accept(tmp);
                    return 0;
                }

                Parameter._foreach(type.parameters, &mangleParameterDg);
                if (type.varargs == 1)
                {
                    tmp.buf.writeByte('Z');
                }
                else
                {
                    tmp.buf.writeByte('@');
                }
            }
            tmp.buf.writeByte('Z');
            const(char)* ret = tmp.buf.extractString();
            memcpy(&saved_idents, &tmp.saved_idents, (const(char)*).sizeof * VC_SAVED_IDENT_CNT);
            memcpy(&saved_types, &tmp.saved_types, Type.sizeof * VC_SAVED_TYPE_CNT);
            return ret;
        }
    }

    extern (C++) const(char)* toCppMangle(Dsymbol s)
    {
        scope VisualCPPMangler v = new VisualCPPMangler(!global.params.mscoff);
        return v.mangleOf(s);
    }

    extern (C++) const(char)* cppTypeInfoMangle(Dsymbol s)
    {
        //printf("cppTypeInfoMangle(%s)\n", s.toChars());
        assert(0);
    }
}
else
{
    static assert(0, "fix this");
}
