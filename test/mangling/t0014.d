extern(C++) void foo(T)(int, T);
static assert(foo!(const(int)*).mangleof == "_Z3fooIPKiEviT_"); 