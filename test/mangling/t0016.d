extern(C++, ns):

struct B(T){}
void foo(A, B)(A, B);

static assert(foo!(int, B!int).mangleof == "_ZN2ns3fooIiNS_1BIiEEEEvT_T0_");