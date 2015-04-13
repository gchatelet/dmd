// extern(C++) {
//     // free functions - test parameters
//     void a0(); static assert(a0.mangleof == "_Z2a0v");
//     void b0(int); static assert(b0.mangleof == "_Z2b0i");
//     void b1(int*); static assert(b1.mangleof == "_Z2b1Pi");
//     void b2(int[3]); static assert(b2.mangleof == "_Z2b2Pi");
//     void b3(int**); static assert(b3.mangleof == "_Z2b3PPi");
//     void c0(const int); static assert(c0.mangleof == "_Z2c0i");
//     void c1(const(int*)); static assert(c1.mangleof == "_Z2c1PKi");
//     void c2(const(int)*); static assert(c2.mangleof == "_Z2c2PKi");
//     void d0(ref int); static assert(d0.mangleof == "_Z2d0Ri");
//     void d1(const ref int); static assert(d1.mangleof == "_Z2d1RKi");
//     // struct member functions
//     struct Struct {
//         static void static_foo(); static assert(static_foo.mangleof == "_ZN6Struct10static_fooEv");
//         void foo(); static assert(foo.mangleof == "_ZN6Struct3fooEv");
//         void const_foo() const; static assert(const_foo.mangleof == "_ZNK6Struct9const_fooEv");
//         void nothrow_foo() nothrow; static assert(nothrow_foo.mangleof == "_ZN6Struct11nothrow_fooEv");
//     }
//     void e0(ref Struct); static assert(e0.mangleof == "_Z2e0R6Struct");
//     void e1(Struct); static assert(e1.mangleof == "_Z2e16Struct");
//     // class member functions
//     class Class {}
//     void f0(Class); static assert(f0.mangleof == "_Z2f05Class");
//     // free function templates
//     void t0(T)(T); static assert(t0!int.mangleof == "_Z2t0IiEvT_");
//     void t1(A,B,C)(A,ref B,C); static assert(t1!(int,char,uint).mangleof == "_Z2t1IicjEvT_RT0_T1_");
// }
// 
// extern(C++, ns) {
//     void ns_a0(); static assert(ns_a0.mangleof == "_ZN2ns5ns_a0Ev");
// }
// 
// extern(C++, ns0.ns1.ns2) {
//     void ns0_ns1_ns2_a0(); static assert(ns0_ns1_ns2_a0.mangleof == "_ZN3ns03ns13ns214ns0_ns1_ns2_a0Ev");
// }
// 
// extern(C++, nested) {
//     struct NestedStruct {}
//     void nested0(NestedStruct); static assert(nested0.mangleof == "_ZN6nested7nested0ENS_12NestedStructE");
// 
//     struct NestedTemplatedStruct(A) {
//         B* templatedMemberFunction(B)(const(B)**) const;
//     };
//     static assert(NestedTemplatedStruct!int.templatedMemberFunction!char.mangleof == "_ZN6nested21NestedTemplatedStructIiE23templatedMemberFunctionIcEEPT_PPKS3_");
// }

extern(C++, std) {
    struct allocator(T) { }
    struct char_traits(CharT) { }
    struct basic_string(T, TRAITS = char_traits!T, ALLOC = allocator!T) {
        bool empty() nothrow const;
        size_t find_first_of(ref const basic_string str, size_t pos = 0) nothrow const;
    }
    struct basic_istream(T, TRAITS = char_traits!T) {
        bool empty() nothrow const;
    }
    struct basic_ostream(T, TRAITS = char_traits!T) {
        bool empty() nothrow const;
    }
    struct basic_iostream(T, TRAITS = char_traits!T) {
        bool empty() nothrow const;
    }
    struct vector(T, A = allocator!T)
    {
        void push_back(ref const T);
    }
    void foo14(std.vector!(int) p);
}

alias basic_string!char std_string;
alias basic_istream!char std_istream;
alias basic_ostream!char std_ostream;
alias basic_iostream!char std_iostream;

// static assert(std_iostream.empty.mangleof=="_ZNKSd5emptyEv");
// static assert(std_string.empty.mangleof=="_ZNKSs5emptyEv");
// static assert(std_istream.empty.mangleof=="_ZNKSi5emptyEv");
// static assert(std_ostream.empty.mangleof=="_ZNKSo5emptyEv");
// static assert(std_string.find_first_of.mangleof=="_ZNKSs13find_first_ofERKSsm");
static assert(std.foo14.mangleof=="_ZSt5foo14St6vectorIiSaIiEE");

void main() {}