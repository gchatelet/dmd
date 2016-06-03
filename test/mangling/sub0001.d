extern(C++, std):

struct allocator(T) {
    void foo() {}
}

static assert(allocator!int.foo.mangleof == "_ZNSaIiE3fooEv");
