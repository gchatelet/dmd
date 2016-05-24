extern(C++):

void foo(char, int, short);
static assert(foo.mangleof == "_Z3foocis");
