extern(C++):
class Expression;
void foo(Expression);

static assert(foo.mangleof == "_Z3foo10Expression");