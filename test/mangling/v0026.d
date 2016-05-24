extern(C++):

A foo(A, B)(B, A, B);
static assert(foo!(char,int).mangleof == "_Z3fooIicET_T0_S0_S1_");
