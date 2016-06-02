extern(C++, std):

void foo();

static assert(foo.mangleof == "_ZSt3foov");
