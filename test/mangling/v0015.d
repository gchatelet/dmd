extern(C++):

void foo(const(const(int)*)*);
static assert(foo.mangleof == "_Z3fooPKPKi");
