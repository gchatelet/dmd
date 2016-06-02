extern(C++):

void foo(const(int)*);
static assert(foo.mangleof == "_Z3fooPKi");
