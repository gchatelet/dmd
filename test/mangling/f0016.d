extern(C++):
class Expression;
void foo(const Expression);

static assert(foo.mangleof == "_Z3fooPK10Expression");