extern(C++):

void foo(int);
static assert(foo.mangleof == "_Z3fooi");
