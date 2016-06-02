extern(C++, std):

struct allocator(T) {}
struct char_traits(CharT) {}
struct basic_string(T, TRAITS = char_traits!T, ALLOC = allocator!T) {
    void foo() {}
}

static assert(basic_string!char.foo.mangleof == "_ZSs3foov");
