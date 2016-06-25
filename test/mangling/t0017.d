extern(C++) void foo(int T)(int[T]);
static assert(foo!5.mangleof == "_Z3fooILi5EEvPi");