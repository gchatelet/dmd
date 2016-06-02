extern(C++, ns):

struct B(T){}
void foo(A, B, C)(A, B, C);

static assert(foo!(B!(B!int), B!int, int).mangleof == "_ZN2ns3fooINS_1BINS1_IiEEEES2_iEEvT_T0_T1_");
