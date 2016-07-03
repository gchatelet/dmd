extern(C++):
class Symbol {}
class Symbol2 {}

class A(T) {
    void foo_template(T t) {}
    void foo_incorrect(Symbol t) {}
    void foo_correct(Symbol2 t) {}
}

static assert(A!(int).foo_template.mangleof == "_ZN1AIiE12foo_templateEi");
static assert(A!(int).foo_incorrect.mangleof == "_ZN1AIiE13foo_incorrectEP6Symbol");
static assert(A!(int).foo_correct.mangleof == "_ZN1AIiE11foo_correctEP7Symbol2");

static assert(A!(Symbol).foo_template.mangleof == "_ZN1AIP6SymbolE12foo_templateES1_");
static assert(A!(Symbol).foo_incorrect.mangleof == "_ZN1AIP6SymbolE13foo_incorrectES1_");
static assert(A!(Symbol).foo_correct.mangleof == "_ZN1AIP6SymbolE11foo_correctEP7Symbol2");
