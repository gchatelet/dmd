class Expression;

extern(C++) void foo(Expression);

static assert(foo.mangleof == "_Z3fooP10Expression");