extern(C++):

const(void function(int)*) baz;
static assert(baz.mangleof == "_ZL3baz");
