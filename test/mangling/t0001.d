extern(C++):

struct A(T) {
    void foo(A);
};
static assert(A!int.foo.mangleof == "_ZN1AIiE3fooES0_");
