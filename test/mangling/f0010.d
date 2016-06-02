extern(C++):

void foo(void function(int));
static assert(foo.mangleof == "_Z3fooPFviE");
