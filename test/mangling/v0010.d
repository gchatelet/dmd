extern(C++):

void foo();
static assert(foo.mangleof == "_Z3foov");
