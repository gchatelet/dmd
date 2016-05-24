extern(C++, std):

struct allocator(T) {}
struct char_traits(CharT) {}
struct basic_string(T, TRAITS = char_traits!T, ALLOC = allocator!T) {
    ref basic_string append(ref const basic_string str, size_t subpos, size_t sublen);
    pragma(mangle, "_ZNKSs5frontEv") ref const(T) front() const;
}
alias basic_string!char std_string;

static assert(std_string.append.mangleof == "_ZNSs6appendERKSsmm");
static assert(std_string.front.mangleof == "_ZNKSs5frontEv");
