extern(C++, a):

struct S {
    void foo();
    void const_foo() const;
}

static assert(S.foo.mangleof == "_ZN1a1S3fooEv");
static assert(S.const_foo.mangleof == "_ZNK1a1S9const_fooEv");
