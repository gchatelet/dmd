extern(C++):

A foo(A, B)(B, A, B);
static assert(foo!(int,char).mangleof == "_Z3fooIicET_T0_S0_S1_");
