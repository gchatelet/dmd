extern(C++) void foo(T)(ref const T);
static assert(foo!int.mangleof == "_Z3fooIiEvRKT_"); 