extern(C++):

__gshared const(int*) bar;
static assert(bar.mangleof == "_ZL3bar");
