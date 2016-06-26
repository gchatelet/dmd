extern(C++):
class Expression;
void foo(Expression);

static assert(foo.mangleof == "_Z3fooP10Expression");