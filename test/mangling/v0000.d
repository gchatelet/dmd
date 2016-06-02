extern(C++):

__gshared int bar;
static assert(bar.mangleof == "bar");
