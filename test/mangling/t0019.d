// template <typename A, typename B> void foo();
// template <> void foo<int *, int *>() {}
extern(C++) void foo(A, B)();
static assert(foo!(int*, int*).mangleof == "_Z3fooIPiS0_Evv");

