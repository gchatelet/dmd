extern(C++, std):

struct A {}
void foo(A);
static assert(foo.mangleof == "_ZSt3fooSt1A");
