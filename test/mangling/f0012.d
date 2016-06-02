extern(C++, a):

struct A {}
void foo(A);
static assert(foo.mangleof == "_ZN1a3fooENS_1AE");
