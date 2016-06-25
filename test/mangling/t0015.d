// template <typename A, typename B, typename C> C &foo(B *, const A *);
// template <> int **&foo<int *, const int *, int **>(const int **, int *const *) {}
extern(C++) ref C foo(A, B, C)(B*, const(A)*);
static assert(foo!(int*, const(int)*, int**).mangleof == "_Z3fooIPiPKiPS0_ERT1_PT0_PKT_"); 