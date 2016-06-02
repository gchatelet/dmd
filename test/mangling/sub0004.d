extern(C++, std):

struct char_traits(CharT) {}
struct basic_istream(T, TRAITS = char_traits!T) {
    void foo() {}
}

static assert(basic_istream!char.foo.mangleof == "_ZSi3foov");
