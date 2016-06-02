extern(C++):

A foo(A, B)(B, A, B);
static assert(foo!(int,int).mangleof == "_Z3fooIiiET_T0_S0_S1_");
