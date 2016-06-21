extern(C++) void foo(int T)();
static assert(foo!5.mangleof == "_Z3fooILi5EEvi");