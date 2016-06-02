extern(C++):

struct A {
    void foo(T)(T, T);
};
static assert(A.foo!int.mangleof == "_ZN1A3fooIiEEvT_S1_");
