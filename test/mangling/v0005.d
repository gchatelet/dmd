extern(C++, std):

__gshared int bar;
static assert(bar.mangleof == "_ZSt3bar");
