extern(C++):

void foo(void*, void*);
static assert(foo.mangleof == "_Z3fooPvS_");
