extern(C++, std):

struct basic_string {
    void foo() {}
}

static assert(basic_string.mangleof == "_ZSb3foov");
