extern(C++, std):

struct allocator(T) {}
struct char_traits(CharT) {}
struct basic_string(T, TRAITS = char_traits!T, ALLOC = allocator!T) {
    void foo() {}
}

// This test is disabled since I didn't find out to produce such a
// substitution in C++.

// static assert(basic_string!int.foo.mangleof == "_ZSb3foov");
