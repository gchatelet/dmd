extern(C++, std):

struct allocator(T) {}
struct char_traits(CharT) {}
struct basic_string(T, TRAITS = char_traits!T, ALLOC = allocator!T) {
}

static assert(std.basic_string.mangleof == "_ZSb3foov");
