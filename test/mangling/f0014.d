extern(C++):

struct A {
    struct B{}
    void foo(B);
};
static assert(A.foo.mangleof == "_ZN1A3fooENS_1BE");
