extern(C++):

__gshared void function(int) baz;
static assert(baz.mangleof == "baz");
