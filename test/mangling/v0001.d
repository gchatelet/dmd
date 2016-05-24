extern(C++):

void function(int) baz;
static assert(baz.mangleof == "baz");
