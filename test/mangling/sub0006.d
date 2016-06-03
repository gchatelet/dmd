extern(C++, std):

struct char_traits(CharT) {}
struct basic_iostream(T, TRAITS = char_traits!T) {
    void foo() {}
}

static assert(basic_iostream!char.foo.mangleof == "_ZNSd3fooEv");
