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

    class OutputBufferContext {
        bool mangleAsCpp;
    }

    class OutputBuffer {
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

        this(OutputBufferContext context) { this.ctx = context; }
        void append(char c) { buffer ~= c; }
        void append(const(char)[] other) { buffer ~= other; }
        OutputBuffer fork() { return new OutputBuffer(ctx); }
        void merge(in OutputBuffer other, bool isEnclosed) {
            if (isEnclosed) append('N');
            append(other.buffer);
            if (isEnclosed) append('E');
        }
        void appendName(string name) {
            if(ctx.mangleAsCpp)
                writeBase10(name.length, buffer);
            append(name);
        }
        const(char)* finish() { append('\0'); return buffer.ptr; }
        const(char)[] buffer;
        OutputBufferContext ctx;
    }

    bool isNested(CppNode node) {
        assert(node);
        while(node.isIndirection) node = node.isIndirection.next;
        auto symbol = node.isSymbol;
        assert(symbol);
        return symbol.parent !is null;
    }

    bool isEnclosed(CppSymbol symbol) {
        bool isDeclaration;
        bool isStd;
        size_t scopes;
        void walkUp(CppSymbol symbol) {
          isDeclaration |= symbol.isDeclaration;
          isStd |= symbol.isStd;
          if (symbol.isScope) ++scopes;
          if (symbol.parent) walkUp(symbol.parent);
        }
        walkUp(symbol);
        if(scopes == 1 && isStd)      return false;
        if(isDeclaration && scopes > 0) return true;
        return scopes > 1 && !isStd;
    }

    void mangleTemplateInstance(CppTemplateInstance tmpl, OutputBuffer output) {
        assert(tmpl);
        output.append('I');
        foreach (argument ; tmpl.template_args) {
            argument.mangleNode(output);
        }
        output.append('E');
    }

    void mangleHierarchy(CppSymbol symbol, OutputBuffer output) {
        if(symbol is null) return;
        assert(symbol.isScope);
        if (symbol.isStd) {
            output.append("St");
        } else if (symbol.isAllocator) {
            output.append("Sa");
            if(auto tmpl = symbol.tmpl) mangleTemplateInstance(tmpl, output);
        } else if (symbol.isBasicStreamInstance!"i") {
            output.append("Si");
        } else if (symbol.isBasicStreamInstance!"o") {
            output.append("So");
        } else if (symbol.isBasicStreamInstance!"io") {
            output.append("Sd");
        } else if (symbol.isBasicStringInstance) {
            output.append("Ss");
        } else if (symbol.isBasicString) {
            output.append("Sb");
            if(auto tmpl = symbol.tmpl) mangleTemplateInstance(tmpl, output);
        } else {
            mangleHierarchy(symbol.parent, output);
            output.appendName(symbol.name);
            if(auto tmpl = symbol.tmpl) mangleTemplateInstance(tmpl, output);
        }
    }

    void mangleNode(CppNode node, OutputBuffer output) {
        assert(node);
        if (auto indirection = node.isIndirection) {
            indirection.mangleIndirection(output).mangleNode(output);
        } else if (auto symbol = node.isSymbol) {
            symbol.mangleSymbol(output);
        } else {
            assert(0);
        }
    }

    void mangleDeclaration(CppSymbol symbol, OutputBuffer final_output) {
        assert(symbol.isDeclaration);
        auto function_type_symbol = symbol.kind == CppSymbol.Kind.FuncDeclaration ? symbol.declaration_type.isSymbol : null;
        {
            scope OutputBuffer output = final_output.fork();
            if(symbol.declaration_const) {
                if (symbol.kind == CppSymbol.Kind.VarDeclaration)
                    output.append('L');
                else if (symbol.kind == CppSymbol.Kind.FuncDeclaration)
                    output.append('K');
                else assert(0);
            }
            mangleHierarchy(symbol.parent, output);
            output.appendName(symbol.name);
            if (function_type_symbol && function_type_symbol.tmpl) {
                mangleTemplateInstance(function_type_symbol.tmpl, output);
            }
            final_output.merge(output, isEnclosed(symbol));
        }
        if (function_type_symbol) {
            foreach(arg; function_type_symbol.function_args) {
                mangleNode(arg, final_output);
            }
        }
    }

    void mangleSymbol(CppSymbol symbol, OutputBuffer output) {
        assert(symbol);
        final switch(symbol.kind) {
            case CppSymbol.Kind.Basic:
                output.append(symbol.name);
                break;
            case CppSymbol.Kind.Namespace:
                output.appendName(symbol.name);
                break;
            case CppSymbol.Kind.Struct:
            case CppSymbol.Kind.Class:
                scope OutputBuffer buffer = output.fork();
                mangleHierarchy(symbol, buffer);
                output.merge(buffer, isEnclosed(symbol));
                break;
            case CppSymbol.Kind.Function:
                output.append("^O^");
                break;
            case CppSymbol.Kind.VarDeclaration:
            case CppSymbol.Kind.FuncDeclaration:
                mangleDeclaration(symbol, output);
                break;
        }
    }

    CppNode mangleIndirection(CppIndirection indirection, OutputBuffer output) {
        assert(indirection);
        char getEncoding() {
            final switch(indirection.kind) {
                case CppIndirection.Kind.Pointer:   return 'P';
                case CppIndirection.Kind.Reference: return 'R';
                case CppIndirection.Kind.Const:     return 'K';
            }
        }
        output.append(getEncoding());
        return indirection.next;
    }

    class CppManglerContext {
    }

    class CppNode {
        CppIndirection isIndirection() { return null; }
        CppSymbol isSymbol() { return null; }
        CppTemplateInstance isTemplateInstance() { return null; }
        abstract void toString(ref char[] buffer);
    }

    // Pointer, Reference or Const
    final class CppIndirection: CppNode {
        CppNode next;
        enum Kind { Pointer, Reference, Const};
        Kind kind;

        this(CppNode node, Kind kind) {
            assert(node);
            this.next = node;
            this.kind = kind;
        }

        override typeof(this) isIndirection() { return this; }

        static CppIndirection toConst(CppNode node) { return new this(node, Kind.Const); }
        static CppIndirection toPtr(CppNode node) { return new this(node, Kind.Pointer); }
        static CppIndirection toRef(CppNode node) { return new this(node, Kind.Reference); }

        override void toString(ref char[] buffer) {
            final switch(kind) {
                case Kind.Pointer:      buffer~="Ptr  "; break;
                case Kind.Reference:    buffer~="Ref  "; break;
                case Kind.Const:        buffer~="Const"; break;
            }
        }
    }

    final class CppTemplateInstance: CppNode {
        CppSymbol source;
        CppNode[] template_args;

        this(CppSymbol source) { this.source = source; }

        override typeof(this) isTemplateInstance() { return this; }
        override void toString(ref char[] buffer) { assert(0); }

        bool matchesSubstitutionTemplateArguments(size_t expected_arguments) {
            assert(expected_arguments > 0);
            return template_args.length == expected_arguments
                    && template_args[0].isSymbol
                    && template_args[0].isSymbol.isCharType;
        }
    }

    final class CppSymbol: CppNode {
        string name;
        enum Kind { Namespace, Struct, Class, Function, Basic, FuncDeclaration, VarDeclaration };
        Kind kind;
        CppSymbol parent;
        CppNode declaration_type;
        bool declaration_const;
        CppTemplateInstance tmpl;
        CppNode function_return_type;
        CppNode[] function_args;

        this(string name, Kind kind) {
            this.name = name;
            this.kind = kind;
        }

        override typeof(this) isSymbol() { return this; }

        override void toString(ref char[] buffer) {
            final switch(kind) {
                case Kind.Namespace:        buffer~="Namespace "; break;
                case Kind.Struct:           buffer~="Struct "; break;
                case Kind.Class:            buffer~="Class "; break;
                case Kind.Function:         buffer~="Function "; break;
                case Kind.FuncDeclaration:  buffer~="FuncDeclaration "; break;
                case Kind.VarDeclaration:   buffer~="VarDeclaration "; break;
                case Kind.Basic:            buffer~="Basic "; break;
            }
            if(name) {
                buffer ~= "'";
                buffer ~= name;
                buffer ~= "'";
            }
            if(tmpl) {
                buffer ~= " (tmpl)";
            }
        }

        bool isCharType() {
            return kind == Kind.Basic && name == "c";
        }

        bool isValueType () {
            return kind == Kind.Struct || kind == Kind.Class || kind == Kind.Basic;
        }

        bool isDeclaration() {
            return kind == Kind.VarDeclaration || kind == Kind.FuncDeclaration;
        }

        bool isScope() {
            return isAggregate() || kind == Kind.Namespace;
        }

        bool isAggregate() {
            return kind == Kind.Struct || kind == Kind.Class;
        }

        bool isStd() {
            return kind == Kind.Namespace && name == "std" && parent is null;
        }

        bool isAllocator() {
            return isAggregate() && name == "allocator" && parent && parent.isStd();
        }

        bool isBasicString() {
            return isAggregate() && name == "basic_string" && parent && parent.isStd();
        }

        bool isBasicStringInstance() {
            return isBasicString && tmpl && tmpl.matchesSubstitutionTemplateArguments(3);
        }

        bool isBasicStreamInstance(string type)() {
            static assert(type == "i" || type == "o" || type == "io");
            return isAggregate() && name == "basic_" ~ type ~ "stream" && parent && parent.isStd() && tmpl && tmpl.matchesSubstitutionTemplateArguments(2);
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
        override void visit(ClassDeclaration e) { output = create(e, CppSymbol.Kind.Class); }
        override void visit(StructDeclaration e){ output = create(e, CppSymbol.Kind.Struct); }
        override void visit(Nspace e)           { output = create(e, CppSymbol.Kind.Namespace); }
        override void visit(VarDeclaration e)   { output = createDecl(e, CppSymbol.Kind.VarDeclaration); }
        override void visit(FuncDeclaration e)  { output = createDecl(e, CppSymbol.Kind.FuncDeclaration); }
        override void visit(TemplateInstance e) { assert(0); }

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
            current.declaration_type = removeConstForValueType(TypeVisitor.create(symbol.type));
            current.declaration_const = symbol.isConst;
            return current;
        }

        CppTemplateInstance createTemplateInstance(CppSymbol source, TemplateInstance templateInstance) {
            auto output = new CppTemplateInstance(source);
            auto arguments = templateInstance.tiargs;
            assert(arguments);
            if(arguments.dim) {
                foreach(argument; *arguments) {
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
        CppNode output;
        static auto create(Type s) {
            scope visitor = new this();
            s.accept(visitor);
            return visitor.output;
        }
        override void visit(TypeEnum s)       { fail("TypeEnum"); }
        override void visit(TypeError s)      { fail("TypeError"); }
        override void visit(TypeNext s)       { fail("TypeNext"); }
        override void visit(TypeArray s)      { fail("TypeArray"); }
        override void visit(TypeAArray s)     { fail("TypeAArray"); }
        override void visit(TypeDArray s)     { fail("TypeDArray"); }
        override void visit(TypeSArray s)     { fail("TypeSArray"); }
        override void visit(TypeDelegate s)   { fail("TypeDelegate"); }
        override void visit(TypeBasic s)      { output = createTypeBasic(s); }
        override void visit(TypeClass s)      { output = adaptConstness(s, ScopeHierarchy.create(s.sym)); }
        override void visit(TypeFunction s)   { output = adaptConstness(s, createFunction(s)); }
        override void visit(TypePointer s)    { output = adaptConstness(s, CppIndirection.toPtr(create(s.next))); }
        override void visit(TypeReference s)  { output = adaptConstness(s, CppIndirection.toRef(create(s.next))); }
        override void visit(TypeStruct s)     { output = adaptConstness(s, ScopeHierarchy.create(s.sym)); }
        override void visit(TypeSlice s)      { fail("TypeSlice"); }
        override void visit(TypeNull s)       { fail("TypeNull"); }
        override void visit(TypeQualified s)  { fail("TypeQualified "); }
        override void visit(TypeIdentifier s) { fail("TypeIdentifier"); }
        override void visit(TypeInstance s)   { fail("TypeInstance"); }
        override void visit(TypeReturn s)     { fail("TypeReturn"); }
        override void visit(TypeTypeof s)     { fail("TypeTypeof"); }
        override void visit(TypeTuple s)      { fail("TypeTuple"); }
        override void visit(TypeVector s)     { fail("TypeVector"); }

        void fail(const(char)* type) {
            error(Loc(), "Internal Compiler Error: can't mangle type %s", type);
        }

        extern(D):
        static auto unConst(T)(T type) {
            const mod = type.mod & ~MODconst;
            return cast(T)type.castMod(mod);
        }

        CppNode adaptConstness(Type type, CppNode node) {
            return type.isConst ? CppIndirection.toConst(node) : node;
        }

        CppSymbol createFunction(TypeFunction typeFun) {
            auto output = new CppSymbol("", CppSymbol.Kind.Function);
            assert(typeFun);
            output.function_return_type =  removeConstForValueType(TypeVisitor.create(typeFun.next));
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

    extern (C++) final class Typename : Visitor
    {
        import ddmd.aggregate;
        import ddmd.dclass;
        import ddmd.denum;
        import ddmd.dmodule;
        import ddmd.dstruct;
        import ddmd.nspace;
        import ddmd.dimport;
        import ddmd.dversion;
        import ddmd.staticassert;
        import ddmd.aliasthis;
        import ddmd.link;
        import ddmd.attrib;
        import ddmd.declaration;
        import ddmd.statement;
        alias visit = super.visit;
        const(char)* name;
        static const(char*) get(RootObject s) {
            scope visitor = new Typename();
            if(auto sym = isDsymbol(s)) sym.accept(visitor);
            else if(auto type = isType(s))  type.accept(visitor);
            else assert(0);
            return visitor.name;
        }
        // Dsymbol
        override void visit(AggregateDeclaration) { name = "AggregateDeclaration"; }
        override void visit(AliasDeclaration) { name = "AliasDeclaration"; }
        override void visit(AliasThis) { name = "AliasThis"; }
        override void visit(AlignDeclaration) { name = "AlignDeclaration"; }
        override void visit(AnonDeclaration) { name = "AnonDeclaration"; }
        override void visit(ArrayScopeSymbol) { name = "ArrayScopeSymbol"; }
        override void visit(AttribDeclaration) { name = "AttribDeclaration"; }
        override void visit(ClassDeclaration) { name = "ClassDeclaration"; }
        override void visit(CompileDeclaration) { name = "CompileDeclaration"; }
        override void visit(ConditionalDeclaration) { name = "ConditionalDeclaration"; }
        override void visit(CtorDeclaration) { name = "CtorDeclaration"; }
        override void visit(DebugSymbol) { name = "DebugSymbol"; }
        override void visit(Declaration) { name = "Declaration"; }
        override void visit(DeleteDeclaration) { name = "DeleteDeclaration"; }
        override void visit(DeprecatedDeclaration) { name = "DeprecatedDeclaration"; }
        override void visit(DtorDeclaration) { name = "DtorDeclaration"; }
        override void visit(EnumDeclaration) { name = "EnumDeclaration"; }
        override void visit(EnumMember) { name = "EnumMember"; }
        override void visit(FuncAliasDeclaration) { name = "FuncAliasDeclaration"; }
        override void visit(FuncDeclaration) { name = "FuncDeclaration"; }
        override void visit(FuncLiteralDeclaration) { name = "FuncLiteralDeclaration"; }
        override void visit(Import) { name = "Import"; }
        override void visit(InterfaceDeclaration) { name = "InterfaceDeclaration"; }
        override void visit(InvariantDeclaration) { name = "InvariantDeclaration"; }
        override void visit(LabelDsymbol) { name = "LabelDsymbol"; }
        override void visit(LinkDeclaration) { name = "LinkDeclaration"; }
        override void visit(Module) { name = "Module"; }
        override void visit(NewDeclaration) { name = "NewDeclaration"; }
        override void visit(Nspace) { name = "Nspace"; }
        override void visit(OverDeclaration) { name = "OverDeclaration"; }
        override void visit(OverloadSet) { name = "OverloadSet"; }
        override void visit(Package) { name = "Package"; }
        override void visit(PostBlitDeclaration) { name = "PostBlitDeclaration"; }
        override void visit(PragmaDeclaration) { name = "PragmaDeclaration"; }
        override void visit(ProtDeclaration) { name = "ProtDeclaration"; }
        override void visit(ScopeDsymbol) { name = "ScopeDsymbol"; }
        override void visit(SharedStaticCtorDeclaration) { name = "SharedStaticCtorDeclaration"; }
        override void visit(SharedStaticDtorDeclaration) { name = "SharedStaticDtorDeclaration"; }
        override void visit(StaticAssert) { name = "StaticAssert"; }
        override void visit(StaticCtorDeclaration) { name = "StaticCtorDeclaration"; }
        override void visit(StaticDtorDeclaration) { name = "StaticDtorDeclaration"; }
        override void visit(StaticIfDeclaration) { name = "StaticIfDeclaration"; }
        override void visit(StorageClassDeclaration) { name = "StorageClassDeclaration"; }
        override void visit(StructDeclaration) { name = "StructDeclaration"; }
        override void visit(SymbolDeclaration) { name = "SymbolDeclaration"; }
        override void visit(TemplateDeclaration) { name = "TemplateDeclaration"; }
        override void visit(TemplateInstance) { name = "TemplateInstance"; }
        override void visit(TemplateMixin) { name = "TemplateMixin"; }
        override void visit(ThisDeclaration) { name = "ThisDeclaration"; }
        override void visit(TupleDeclaration) { name = "TupleDeclaration"; }
        override void visit(TypeInfoArrayDeclaration) { name = "TypeInfoArrayDeclaration"; }
        override void visit(TypeInfoAssociativeArrayDeclaration) { name = "TypeInfoAssociativeArrayDeclaration"; }
        override void visit(TypeInfoClassDeclaration) { name = "TypeInfoClassDeclaration"; }
        override void visit(TypeInfoConstDeclaration) { name = "TypeInfoConstDeclaration"; }
        override void visit(TypeInfoDeclaration) { name = "TypeInfoDeclaration"; }
        override void visit(TypeInfoDelegateDeclaration) { name = "TypeInfoDelegateDeclaration"; }
        override void visit(TypeInfoEnumDeclaration) { name = "TypeInfoEnumDeclaration"; }
        override void visit(TypeInfoFunctionDeclaration) { name = "TypeInfoFunctionDeclaration"; }
        override void visit(TypeInfoInterfaceDeclaration) { name = "TypeInfoInterfaceDeclaration"; }
        override void visit(TypeInfoInvariantDeclaration) { name = "TypeInfoInvariantDeclaration"; }
        override void visit(TypeInfoPointerDeclaration) { name = "TypeInfoPointerDeclaration"; }
        override void visit(TypeInfoSharedDeclaration) { name = "TypeInfoSharedDeclaration"; }
        override void visit(TypeInfoStaticArrayDeclaration) { name = "TypeInfoStaticArrayDeclaration"; }
        override void visit(TypeInfoStructDeclaration) { name = "TypeInfoStructDeclaration"; }
        override void visit(TypeInfoTupleDeclaration) { name = "TypeInfoTupleDeclaration"; }
        override void visit(TypeInfoVectorDeclaration) { name = "TypeInfoVectorDeclaration"; }
        override void visit(TypeInfoWildDeclaration) { name = "TypeInfoWildDeclaration"; }
        override void visit(UnionDeclaration) { name = "UnionDeclaration"; }
        override void visit(UnitTestDeclaration) { name = "UnitTestDeclaration"; }
        override void visit(UserAttributeDeclaration) { name = "UserAttributeDeclaration"; }
        override void visit(VarDeclaration) { name = "VarDeclaration"; }
        override void visit(VersionSymbol) { name = "VersionSymbol"; }
        override void visit(WithScopeSymbol) { name = "WithScopeSymbol"; }

        // Type
        override void visit(TypeAArray) { name = "TypeAArray"; }
        override void visit(TypeArray) { name = "TypeArray"; }
        override void visit(TypeBasic) { name = "TypeBasic"; }
        override void visit(TypeClass) { name = "TypeClass"; }
        override void visit(TypeDArray) { name = "TypeDArray"; }
        override void visit(TypeDelegate) { name = "TypeDelegate"; }
        override void visit(TypeEnum) { name = "TypeEnum"; }
        override void visit(TypeError) { name = "TypeError"; }
        override void visit(TypeFunction) { name = "TypeFunction"; }
        override void visit(TypeIdentifier) { name = "TypeIdentifier"; }
        override void visit(TypeInstance) { name = "TypeInstance"; }
        override void visit(TypeNext) { name = "TypeNext"; }
        override void visit(TypeNull) { name = "TypeNull"; }
        override void visit(TypePointer) { name = "TypePointer"; }
        override void visit(TypeQualified) { name = "TypeQualified"; }
        override void visit(TypeReference) { name = "TypeReference"; }
        override void visit(TypeReturn) { name = "TypeReturn"; }
        override void visit(TypeSArray) { name = "TypeSArray"; }
        override void visit(TypeSlice) { name = "TypeSlice"; }
        override void visit(TypeStruct) { name = "TypeStruct"; }
        override void visit(TypeTuple) { name = "TypeTuple"; }
        override void visit(TypeTypeof) { name = "TypeTypeof"; }
        override void visit(TypeVector) { name = "TypeVector"; }
    }

    extern (C++) final class Scopes: Visitor
    {
        import ddmd.dmodule;
        alias visit = super.visit;
        static auto get(Dsymbol s) {
            scope visitor = new Scopes();
            s.accept(visitor);
            return visitor.scopes;
        }
        override void visit(Module e) { /* stop climbing symbols here */ }
        override void visit(ScopeDsymbol e) { e.parent.accept(this); scopes~=e; }
        override void visit(Declaration e) { e.parent.accept(this); }
        ScopeDsymbol[] scopes;
    }

    extern (C++) final class Nesting: Visitor
    {
        import ddmd.dmodule;
        alias visit = super.visit;
        static auto get(Dsymbol s) {
//             printf("Nesting visit %s %s\n", Typename.get(s), s.toChars());
            scope visitor = new Nesting();
            s.accept(visitor);
            return visitor.isNested();
        }
        override void visit(Module e) { /* stop climbing symbols here */ }
        override void visit(Declaration e) {
            declaration = e;
            e.parent.accept(this);
        }
        override void visit(ScopeDsymbol e) {
            ++scopes;
            if(e.isNspace && e.ident is Id.std) {
                isStd = true;
            }
            e.parent.accept(this);
        }
        override void visit(TemplateInstance e) {
            e.parent.accept(this);
        }
        bool isNested() const {
//             printf("scopes: %d, isStd: %d, isDeclaration %x\n", scopes, isStd, declaration);
            if(scopes == 1 && isStd)      return false;
            if(declaration && scopes > 0) return true;
            return scopes > 1 && !isStd;
        }
        bool isStd;
        size_t scopes;
        Declaration declaration;
    }

    extern (C++) final class ValueType: Visitor
    {
        import ddmd.dmodule;
        alias visit = super.visit;
        bool isValueType = false;
        static bool get(Type s) {
            scope visitor = new ValueType();
            s.accept(visitor);
            return visitor.isValueType;
        }
        override void visit(Type s)           { isValueType = false;  }
        override void visit(TypeBasic s)      { isValueType = true;  }
        override void visit(TypeClass s)      { isValueType = true;  }
        override void visit(TypeEnum s)       { isValueType = true;  }
        override void visit(TypeStruct s)     { isValueType = true;  }
    }
    extern (C++) final class IsTypeClass: Visitor
    {
        import ddmd.dmodule;
        alias visit = super.visit;
        bool value = false;
        static bool get(Type s) {
            scope visitor = new IsTypeClass();
            s.accept(visitor);
            return visitor.value;
        }
        override void visit(Type s)           { value = false;  }
        override void visit(TypeClass s)      { value = true;  }
    }
    extern (C++) final class Types: Visitor
    {
        import ddmd.dmodule;
        alias visit = super.visit;
        Appender ctx;
        int indirections;
        this(Appender ctx) {
            this.ctx = ctx;
        }
        static void mangle(Type s, Appender ctx) {
//             printf("%s: %s\n", Typename.get(s), s.toChars());
            scope visitor = new Types(ctx);
            s.accept(visitor);
        }
        override void visit(TypeBasic s)      { mangleTypeBasic(s); }
        override void visit(TypeClass s)      { mangleTypeClass(s); }
        override void visit(TypeEnum s)       { fail("TypeEnum"); }
        override void visit(TypeError s)      { fail("TypeError"); }
        override void visit(TypeNext s)       { fail("TypeNext"); }
        override void visit(TypeArray s)      { fail("TypeArray"); }
        override void visit(TypeAArray s)     { fail("TypeAArray"); }
        override void visit(TypeDArray s)     { fail("TypeDArray"); }
        override void visit(TypeSArray s)     { fail("TypeSArray"); }
        override void visit(TypeDelegate s)   { fail("TypeDelegate"); }
        override void visit(TypeFunction s)   { mangleTypeFunction(s); }
        override void visit(TypePointer s)    { mangleIndirection(s, 'P'); }
        override void visit(TypeReference s)  { mangleIndirection(s, 'R'); }
        override void visit(TypeSlice s)      { fail("TypeSlice"); }
        override void visit(TypeNull s)       { fail("TypeNull"); }
        override void visit(TypeQualified s)  { fail("TypeQualified "); }
        override void visit(TypeIdentifier s) { fail("TypeIdentifier"); }
        override void visit(TypeInstance s)   { fail("TypeInstance"); }
        override void visit(TypeReturn s)     { fail("TypeReturn"); }
        override void visit(TypeTypeof s)     { fail("TypeTypeof"); }
        override void visit(TypeStruct s)     { mangleTypeStruct(s); }
        override void visit(TypeTuple s)      { fail("TypeTuple"); }
        override void visit(TypeVector s)     { fail("TypeVector"); }

        void fail(const(char)* type) {
            ctx.add('.');
            error(Loc(), "Internal Compiler Error: can't mangle type %s", type);
        }

        extern(D):
        static auto unConst(T)(T type) {
            // Now mangling the non-const type.
            const mod = type.mod & ~MODconst;
            return cast(T)type.castMod(mod);
        }

        void handleConstness(Type type, void delegate() fun) {
            if (type.isConst) {
                ctx.substituteOrMangle(type, () {
                    ctx.add('K');
                    unConst(type).accept(this);
                });
            } else {
                ctx.substituteOrMangle(type, fun);
            }
        }

        void mangleTypeClass(TypeClass type) {
            handleConstness(type, () {
                mangleAggegateDeclaration(type.sym, ctx);
            });
        }

        void mangleTypeStruct(TypeStruct type) {
            handleConstness(type, () {
                mangleAggegateDeclaration(type.sym, ctx);
            });
        }

        void mangleTypeFunction(TypeFunction type) {
            handleConstness(type, () {
                ctx.add('F');
                auto returnType = type.next;
                if(type.isref) returnType = returnType.referenceTo();
                Types.mangle(returnType, ctx);
                mangleFunctionParameters(type, ctx);
                ctx.add('E');
            });
        }

        void mangleIndirection(TypeNext type, char mangleCode) {
            handleConstness(type, () {
                ++indirections;
                ctx.add(mangleCode);
                type.next.accept(this);
                --indirections;
            });
        }

        void mangleTypeBasic(TypeBasic type) {
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
            auto encoding = getEncoding(type);
            // We mangle the constness for pointer or reference to basic type
            // but not for basic type alone.
            // e.g. `void foo(const int)` is mangled as `void foo(int)`
            if(type.isConst && indirections > 0) {
                ctx.substituteOrMangle(type, () {
                    ctx.add('K');
                    unConst(type).accept(this);
                });
            } else {
                ctx.substituteOrMangle(type, (){ ctx.add(encoding); });
            }
        }
    }

    import ddmd.identifier;
    import ddmd.id;
    import ddmd.aggregate;

    enum MangleAs { C, CPP }

    static struct TypeProxy {
        Type type;
        size_t toHash() const nothrow @safe {
            return cast(size_t)(type.deco); // using deco's address as hash.
        }

        bool opEquals(ref const TypeProxy other) const nothrow @safe {
            const Type a = type;
            const Type b = other.type;
            assert(a && b);
            return a is b || (a.deco is b.deco && a.deco !is null);
        }
    }

    static struct SymbolProxy {
        Dsymbol symbol;
        const(char)[] name;
        size_t hash;

        this(Dsymbol symbol) {
            this.symbol = symbol;
            const chars = symbol.toChars();
            this.name = chars[0..strlen(chars)];
            this.hash = adler32(name);
        }

        size_t toHash() const @safe pure nothrow {
            return hash;
        }

        bool opEquals(ref const SymbolProxy other) const @safe pure nothrow {
            return name[] == other.name[];
        }

        private static uint adler32(const(void)[] blob) nothrow @safe {
           uint s1 = 1;
           uint s2 = 0;
           foreach (b; cast(const(ubyte)[])blob) {
               s1 = (s1 + b) % 65521;
               s2 = (s2 + s1) % 65521;
           }
           return (s2 << 16) | s1;
       }
    }

    final class Context {
        extern(D):

        void set(MangleAs value) {
            mangleAs = value;
        }

       private static void writeBase36(size_t i, ref string output) {
            if (i >= 36)
            {
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

        private static void writeBase10(size_t i, ref string output) {
            if (i >= 10)
            {
                writeBase10(i / 10, output);
                i %= 10;
            }
            if (i < 10)
                output ~= cast(char)(i + '0');
            else
                assert(0);
        }

        private string nextSubstitution() {
            return getEncoding('S', symbols.length + types.length);
        }

        private string nextTemplateSubstitution() {
            return getEncoding('T', templateTypes.length);
        }

        private static string getEncoding(char type, size_t i) {
            string output;
            output ~= type;
            if (i > 0) writeBase36(i - 1, output);
            output ~= '_';
            return output;
        }

        MangleAs mangleAs;
        string[TypeProxy] types;
        string[TypeProxy] templateTypes;
        string[SymbolProxy] symbols;
        private size_t isInTemplateInstance;
        private bool isInDeclaration;
        private bool useTemplateSubstitutions;
    }

    final class Appender {
        Context ctx;
        alias ctx this;
        this(Context ctx) { this.ctx = ctx; }

        void add(Identifier ident) {
            auto name = cast(string)ident.toString();
            if (mangleAs == MangleAs.CPP) writeBase10(name.length, buffer);
            add(name);
        }

        void add(string s) {
            buffer ~= s;
//             printf("'%.*s'\n", s.length, s.ptr);
        }

        void add(char c) {
            buffer ~= c;
//             printf("'%c'\n", c);
        }

        auto fork() {
            return new Appender(ctx);
        }

        void merge(ref const Appender appender, bool enclosed) {
            if(enclosed) add('N');
            add(appender.buffer);
            if(enclosed) add('E');
        }

        auto finish() {
            buffer ~= '\0';
            printf("finish: %s\n", buffer.ptr);
            return cast(const(char)*)buffer;
        }

        void substituteOrMangle(Type type, void delegate() mangle) {
//             printf("substituteOrMangle isInTemplateInstance: %d isInDeclaration: %d useTemplateSubstitutions: %d, isInDeclarationTemplateInstance %d\n", isInTemplateInstance, isInDeclaration, useTemplateSubstitutions, isInDeclarationTemplateInstance());
            static void addType(Type type, ref string[TypeProxy] map, string id) {
                auto proxy = TypeProxy(type);
                if (proxy !in map) {
                    map[proxy] = id;
//                     printf("Adding type '%s': '%.*s' '%s'\n", proxy.type.deco, id.length, id.ptr, proxy.type.toChars());
                }
            }
            const is_mutable_value_type = ValueType.get(type) && !type.isConst;
//             printf("is_mutable_basic_type: %d\n", is_mutable_basic_type);
            const is_add_symbol = isInDeclarationTemplateInstance || !is_mutable_value_type;
//             printf("is_add_symbol: %d\n", is_add_symbol);
            const is_substitute_symbol = useTemplateSubstitutions || !is_mutable_value_type;
//             printf("is_substitute_symbol: %d\n", is_substitute_symbol);
            if (is_substitute_symbol) {
                auto proxy = TypeProxy(type);
                bool substitute(ref string[TypeProxy] map) {
                    if (auto found = proxy in map) {
                        add(*found);
//                         printf("Substituting type %s: '%s' with '%.*s'\n", Typename.get(type), type.toChars(), found.length, found.ptr);
                        return true;
                    }
                    return false;
                }
                if (useTemplateSubstitutions) {
                    if (substitute(ctx.types)) {
                        return;
                    }
                    if (substitute(ctx.templateTypes)) {
                        // Template substitution is now a regular substitution.
                        addType(type, ctx.types, ctx.nextSubstitution());
                        return;
                    }
                }
                if (substitute(ctx.types)) {
                    return;
                }
            }
            mangle();
            if (is_add_symbol) {
                if (isInDeclarationTemplateInstance) {
                    addType(type, ctx.templateTypes, ctx.nextTemplateSubstitution());
                } else {
                    addType(type, ctx.types, ctx.nextSubstitution());
                }
            }
        }

        string* getSymbolSubstitution(Dsymbol symbol) {
            return SymbolProxy(symbol) in ctx.symbols;
        }

        void addSymbol(Dsymbol symbol) {
            if(isInTemplateInstance) {
                return;
            }
            auto proxy = SymbolProxy(symbol);
            if (proxy !in ctx.symbols) {
                string id = ctx.nextSubstitution();
                ctx.symbols[proxy] = id;
//                 printf("Adding symbol %s %s as %.*s\n", Typename.get(symbol), symbol.toChars(), id.length, id.ptr);
            }
        }

        private bool isInDeclarationTemplateInstance() const {
            return isInDeclaration && isInTemplateInstance;
        }

        private string buffer;
    }

    static void mangleTemplateInstance(TemplateInstance s, Appender ctx) {
        if(s is null) return;
        ctx.isInTemplateInstance++;
        ctx.add('I');
        auto arguments = s.tiargs;
        assert(arguments);
        if (arguments.dim) {
            foreach (argument ; *arguments) {
//                 printf("Mangling argument '%s' of type %s\n", argument.toChars(), Typename.get(argument));
                Types.mangle(cast(Type)argument, ctx);
            }
        } else {
            Types.mangle(Type.tvoid, ctx);
        }
        ctx.add('E');
        ctx.isInTemplateInstance--;
    }

    static void abbreviate(ref ScopeDsymbol[] scopes, Appender ctx) {
        bool isTemplatedId(Dsymbol sym, Identifier id) {
            if(sym is null) return false;
            auto templateInstance = sym.isTemplateInstance;
            return templateInstance && templateInstance.name is id;
        }
        bool isStd(Dsymbol sym) {
            return sym && sym.isNspace && sym.ident is Id.std;
        }
        ScopeDsymbol next() {
            return scopes.length ? scopes[0] : null;
        }
        void pop() {
            assert(scopes.length);
            scopes = scopes[1..$];
        }
        ScopeDsymbol first = next();
        if(isStd(first)) {
            pop();
            ScopeDsymbol second = next();
            if(isTemplatedId(second, Id.basic_string)) {
                ctx.add("Ss");
            } else if(isTemplatedId(second, Id.basic_iostream)) {
                ctx.add("Sd");
            } else if(isTemplatedId(second, Id.basic_ostream)) {
                ctx.add("So");
            } else if(isTemplatedId(second, Id.basic_istream)) {
                ctx.add("Si");
            } else if(isTemplatedId(second, Id.allocator)) {
                ctx.add("Sa");
                mangleTemplateInstance(second.isTemplateInstance, ctx);
            } else {
                ctx.add("St");
                return;
            }
            pop();
            pop();
        }
    }

    static void mangleSymbol(Dsymbol symbol, Appender ctx) {
//         printf(">> Now mangling '%s' of type %s\n", symbol.toChars(), Typename.get(symbol));
        if(!symbol.isTemplateInstance) {
            ctx.add(symbol.ident);
        }
        auto parentTemplateInstance = getParentTemplateInstance(symbol);
        if(parentTemplateInstance) {
            mangleTemplateInstance(parentTemplateInstance , ctx);
        }
        if(!symbol.isDeclaration) {
            ctx.addSymbol(symbol);
        }
    }

    static void mangleSymbols(ScopeDsymbol[] scopes, Appender ctx_, Declaration decl) {
        Dsymbol last = decl ? decl : scopes[$-1];
        scope new_ctx = ctx_.fork();
        if(decl && decl.type.isConst) {
            if(decl.isVarDeclaration) new_ctx.add('L');
            if(decl.isFuncDeclaration) new_ctx.add('K');
        }
        abbreviate(scopes, new_ctx);
        // Substitute if possible.
        foreach_reverse(i, s; scopes) {
            if(string* found = new_ctx.getSymbolSubstitution(s)) {
                new_ctx.add(*found);
                scopes = scopes[i + 1 .. $];
                break;
            }
        }
        // Encode the rest.
        foreach(symbol; scopes) {
            mangleSymbol(symbol, new_ctx);
        }
        // Encode declaration.
        if(decl) {
            new_ctx.isInDeclaration = true;
            mangleSymbol(decl, new_ctx);
            new_ctx.isInDeclaration = false;
        }
        ctx_.merge(new_ctx, Nesting.get(last));
    }

    static void mangleParameter(Parameter parameter, Appender ctx) {
        const isRef = parameter.storageClass & STCref;
        auto type = parameter.type;
        import ddmd.dclass;
        if(IsTypeClass.get(type)) {
//             printf("Adding pointer to '%s'\n", Typename.get(type));
            type = type.pointerTo();
        }
        if(isRef) type = type.referenceTo();
        Types.mangle(type, ctx);
    }

    static void mangleFunctionParameters(TypeFunction typeFun, Appender ctx) {
        assert(typeFun);
        auto parameters = typeFun.parameters;
        assert(parameters);
        if( parameters.dim) {
            foreach(parameter; *parameters) {
                mangleParameter(parameter, ctx);
            }
        } else {
            Types.mangle(Type.tvoid, ctx);
        }
    }

    static TemplateInstance getParentTemplateInstance(Dsymbol decl) {
        if(!decl.parent) return null;
        return decl.parent.isTemplateInstance;
    }

    static void mangleAggegateDeclaration(AggregateDeclaration decl, Appender ctx) {
        auto scopes = Scopes.get(decl);
        mangleSymbols(scopes, ctx, null);
    }

    static void mangleDeclaration(Declaration decl, Appender ctx) {
        auto scopes = Scopes.get(decl);
        const nested = scopes.length > 0;
        const mangleAsCpp = decl.isConst || nested || decl.isFuncDeclaration;
        if(mangleAsCpp) ctx.add("_Z");
        ctx.set(mangleAsCpp ? MangleAs.CPP : MangleAs.C);
        mangleSymbols(scopes, ctx, decl);
        auto funDecl = decl.isFuncDeclaration;
        if(funDecl) {
            if(getParentTemplateInstance(decl)) {
                ctx.useTemplateSubstitutions = true;
                auto funType = cast(TypeFunction)funDecl.type;
                assert(funType);
                auto templateReturnType = funType.next;
                assert(templateReturnType);
                Types.mangle(cast(Type)templateReturnType, ctx);
            }
            mangleFunctionParameters(cast(TypeFunction)funDecl.type, ctx);
        }
    }

    static Dsymbol isDsymbol(RootObject obj) {
        return obj.dyncast == DYNCAST.dsymbol ? cast(Dsymbol)obj : null;
    }

    static Type isType(RootObject obj) {
        return obj.dyncast == DYNCAST.type ? cast(Type)obj : null;
    }

    void print(CppNode node, ref char[] buffer, size_t ident, string prepend) {
        if(node is null) return;
        buffer ~= '\n';
        buffer ~= prepend;
        foreach(_; prepend.length .. ident * 4) buffer ~= ' ';
        node.toString(buffer);
        if(auto s = node.isSymbol) {
            if(auto tmpl = s.tmpl) {
                foreach(arg; tmpl.template_args) {
                    print(arg, buffer, ident + 1, "tmpl");
                }
            }
            if(s.kind == CppSymbol.Kind.Function) {
                print(s.function_return_type, buffer, ident + 1, "ret");
                foreach(arg; s.function_args) {
                    print(arg, buffer, ident + 1, "arg");
                }
            }
        }
        if(auto symbol = node.isSymbol) {
            if(auto type = symbol.declaration_type)
                print(type, buffer, ident + 1, prepend);
            else
                print(symbol.parent, buffer, ident + 1, prepend);
        }
        if(auto indirection = node.isIndirection)
            print(indirection.next, buffer, ident + 1, prepend);
    }

    const(char)* createDeclaration(Declaration decl) {
        CppSymbol node = ScopeHierarchy.create(decl);
//         char[] buffer;
//         print(node, buffer, 2, "");
//         buffer ~= '\0';
//         printf("ToString: %s\n", buffer.ptr);
        scope OutputBufferContext ctx = new OutputBufferContext;
        ctx.mangleAsCpp = decl.isConst || isNested(node) || decl.isFuncDeclaration;
        scope OutputBuffer output = new OutputBuffer(ctx);
        if(ctx.mangleAsCpp) output.append("_Z");
        mangleNode(node, output);
        printf(">>> %s\n", output.finish());
        return output.finish();
    }

    extern (C++) const(char)* toCppMangle(Dsymbol s)
    {
        printf("######################################################\n");
//         printf("toCppMangle(%s)\n", s.toChars());
//         scope ctx = new Context;
//         scope appender = new Appender(ctx);
//         if(s.isVarDeclaration || s.isFuncDeclaration)
//             mangleDeclaration(s.isDeclaration, appender);
//         else
//             error(Loc(), "Internal Compiler Error: unsupported type\n");
//         return appender.finish();
        if(s.isVarDeclaration || s.isFuncDeclaration)
            return createDeclaration(s.isDeclaration);
        error(Loc(), "Internal Compiler Error: unsupported type\n");
        fatal();
        assert(0);
//         scope CppMangleVisitor v = new CppMangleVisitor();
//         return v.mangleOf(s);
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
