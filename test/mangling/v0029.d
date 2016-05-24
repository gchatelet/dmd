extern(C++, std):

struct allocator(T) {}

final class vector(T, ALLOC = allocator!T) {
    void push_back(ref const T _);
}

alias vector!int std_vector_int;


static assert(std_vector_int.push_back.mangleof == "_ZNSt6vectorIiSaIiEE9push_backERKi");



  
