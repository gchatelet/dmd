extern(C++) void foo(T)(T);
static assert(foo!(const(int)*).mangleof == "_Z3fooIPKiEvT_"); 
