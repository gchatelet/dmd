extern(C++):

struct B {}
struct A(T) {
    void foo(T, T);
};
static assert(A!(B).foo.mangleof == "_ZN1AI1BE3fooES0_S0_");
