extern(C++):

void foo(T)(T);
static assert(foo!int.mangleof == "_Z3fooIiEvT_");
