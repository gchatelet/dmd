extern(C++, std):

struct allocator {
    void foo() {}
}

static assert(allocator.foo.mangleof == "_ZSa3foov");
