extern(C++):

void foo(ref const int);
static assert(foo.mangleof == "_Z3fooRKi");
