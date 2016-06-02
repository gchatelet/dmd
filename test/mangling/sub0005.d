extern(C++, std):

struct char_traits(CharT) {}
struct basic_ostream(T, TRAITS = char_traits!T) {
    void foo() {}
}

static assert(basic_ostream!char.foo.mangleof == "_ZSo3foov");
