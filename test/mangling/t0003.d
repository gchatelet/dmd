extern(C++):

struct A(T) {
    void foo(T, T);
};
static assert(A!int.foo.mangleof == "_ZN1AIiE3fooEii");
