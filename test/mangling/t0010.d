extern(C++, ns):

struct B(T){}
void foo(A, B, C)(A, B, C);

static assert(foo!(int, B!int, B!(B!int)).mangleof == "_ZN2ns3fooIiNS_1BIiEENS1_IS2_EEEEvT_T0_T1_");
