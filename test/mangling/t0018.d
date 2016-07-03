extern(C++) void foo(T)(int, ref T);
static assert(foo!(int*).mangleof == "_Z3fooIPiEviRT_");
