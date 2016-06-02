extern(C++, a):

__gshared int bar;
static assert(bar.mangleof == "_ZN1a3barE");
