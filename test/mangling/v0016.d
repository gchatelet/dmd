extern(C++):

void foo(ref int*);
static assert(foo.mangleof == "_Z3fooRPi");
