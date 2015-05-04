
// Test C++ name mangling.
// See Bugs 4059, 5148, 7024, 10058

version(linux):

extern(C++) {
    // free functions - test parameters
    void a0(); static assert(a0.mangleof == "_Z2a0v");
    void b0(int); static assert(b0.mangleof == "_Z2b0i");
    void b1(int*); static assert(b1.mangleof == "_Z2b1Pi");
    void b2(int[3]); static assert(b2.mangleof == "_Z2b2Pi");
    void b3(int**); static assert(b3.mangleof == "_Z2b3PPi");
    void c0(const int); static assert(c0.mangleof == "_Z2c0i");
    void c1(const(int*)); static assert(c1.mangleof == "_Z2c1PKi");
    void c2(const(int)*); static assert(c2.mangleof == "_Z2c2PKi");
    void d0(ref int); static assert(d0.mangleof == "_Z2d0Ri");
    void d1(const ref int); static assert(d1.mangleof == "_Z2d1RKi");
    // struct member functions
    struct Struct {
        void foo(); static assert(foo.mangleof == "_ZN6Struct3fooEv");
        void const_foo() const; static assert(const_foo.mangleof == "_ZNK6Struct9const_fooEv");
    }
    void e0(ref Struct); static assert(e0.mangleof == "_Z2e0R6Struct");
    void e1(Struct); static assert(e1.mangleof == "_Z2e16Struct");
    // class member functions
    class Class {}
    void f0(Class); static assert(f0.mangleof == "_Z2f0P5Class");
    // free function templates
    void t0(T)();
    static assert(t0!int.mangleof == "_Z2t0IiEvv");
    static assert(t0!(TStruct!(TStruct!(TStruct!int))).mangleof == "_Z2t0I7TStructIS0_IS0_IiEEEEvv");
    void t1(T)(T); static assert(t1!int.mangleof == "_Z2t1IiEvT_");
    void t2(A,B,C)(A,ref B,C); static assert(t2!(int,char,uint).mangleof == "_Z2t2IicjEvT_RT0_T1_");
    T t3(T)(T, T); static assert(t3!int.mangleof == "_Z2t3IiET_S0_S0_");
    // template struct
    struct TStruct(A) {
        void f0();
        void f1(A);
        void f2() const;
        struct Inner(B) {
            void g0(A, B);
            void g1(A, B) const;
        }
    }
    static assert(TStruct!int.f0.mangleof == "_ZN7TStructIiE2f0Ev");
    static assert(TStruct!int.f1.mangleof == "_ZN7TStructIiE2f1Ei");
    static assert(TStruct!int.f2.mangleof == "_ZNK7TStructIiE2f2Ev");
    static assert(TStruct!int.Inner!char.g0.mangleof == "_ZN7TStructIiE5InnerIcE2g0Eic");
    static assert(TStruct!int.Inner!char.g1.mangleof == "_ZNK7TStructIiE5InnerIcE2g1Eic");
    static assert(TStruct!int.Inner!int.g0.mangleof == "_ZN7TStructIiE5InnerIiE2g0Eii");
    static assert(TStruct!(Struct).Inner!(Struct).g0.mangleof == "_ZN7TStructI6StructE5InnerIS0_E2g0ES0_S0_");
}

extern(C++, ns) {
    void ns_a0(); static assert(ns_a0.mangleof == "_ZN2ns5ns_a0Ev");
}

extern(C++, ns0.ns1.ns2) {
    void ns0_ns1_ns2_a0(); static assert(ns0_ns1_ns2_a0.mangleof == "_ZN3ns03ns13ns214ns0_ns1_ns2_a0Ev");
}

extern(C++, nested) {
    struct NestedStruct {}
    void nested0(NestedStruct); static assert(nested0.mangleof == "_ZN6nested7nested0ENS_12NestedStructE");

    struct NestedTemplatedStruct(A) {
        B* templatedMemberFunction(B)(const(B)**) const;
    };
    // nested                       S_
    // NestedTemplatedStruct        S0_
    // NestedTemplatedStruct!int    S1_
    // templatedMemberFunction!char S2_
    // char                         S3_
    static assert(NestedTemplatedStruct!int.templatedMemberFunction!char.mangleof == "_ZNK6nested21NestedTemplatedStructIiE23templatedMemberFunctionIcEEPT_PPKS3_");

    // nested                               S_
    // NestedTemplatedStruct                S0_
    // NestedTemplatedStruct!int            S1_
    // templatedMemberFunction!NestedStruct S2_
    // NestedStruct                         S3_
    static assert(NestedTemplatedStruct!int.templatedMemberFunction!NestedStruct.mangleof == "_ZNK6nested21NestedTemplatedStructIiE23templatedMemberFunctionINS_12NestedStructEEEPT_PPKS4_");
}

extern(C++, std) {
    struct allocator(T) { }
    struct char_traits(CharT) { }
    struct basic_string(T, TRAITS = char_traits!T, ALLOC = allocator!T) {
        bool empty() nothrow const;
        size_t find_first_of(ref const basic_string str, size_t pos = 0) nothrow const;
    }
    struct basic_istream(T, TRAITS = char_traits!T) {
        int get();
    }
    struct basic_ostream(T, TRAITS = char_traits!T) {
        ref basic_ostream put(char);
    }
    struct basic_iostream(T, TRAITS = char_traits!T) {
    }
    struct vector(T, A = allocator!T)
    {
        void push_back(ref const T);
        bool empty() const;
    }
    void foo14(std.vector!(int) p);
}

alias basic_string!char std_string;
alias basic_istream!char std_istream;
alias basic_ostream!char std_ostream;
alias basic_iostream!char std_iostream;

static assert(std.vector!int.empty.mangleof);
static assert(std_istream.get.mangleof == "_ZNSi3getEv");
static assert(std_ostream.put.mangleof == "_ZNSo3putEc");
static assert(std_string.empty.mangleof == "_ZNKSs5emptyEv");
static assert(std_string.find_first_of.mangleof == "_ZNKSs13find_first_ofERKSsm");
static assert(std.foo14.mangleof == "_ZSt5foo14St6vectorIiSaIiEE");

import core.stdc.stdio;

extern (C++) int foob(int i, int j, int k);

class C
{
    extern (C++) int bar(int i, int j, int k)
    {
        printf("this = %p\n", this);
        printf("i = %d\n", i);
        printf("j = %d\n", j);
        printf("k = %d\n", k);
        return 1;
    }
}


extern (C++)
int foo(int i, int j, int k)
{
    printf("i = %d\n", i);
    printf("j = %d\n", j);
    printf("k = %d\n", k);
    assert(i == 1);
    assert(j == 2);
    assert(k == 3);
    return 1;
}

void test1()
{
    foo(1, 2, 3);

    auto i = foob(1, 2, 3);
    assert(i == 7);

    C c = new C();
    c.bar(4, 5, 6);
}

static assert(foo.mangleof == "_Z3fooiii");
static assert(foob.mangleof == "_Z4foobiii");
static assert(C.bar.mangleof == "_ZN1C3barEiii");

/****************************************/

extern (C++)
interface D
{
    int bar(int i, int j, int k);
}

extern (C++) D getD();

void test2()
{
    D d = getD();
    int i = d.bar(9,10,11);
    assert(i == 8);
}

static assert (getD.mangleof == "_Z4getDv");
static assert (D.bar.mangleof == "_ZN1D3barEiii");

/****************************************/

extern (C++) int callE(E);

extern (C++)
interface E
{
    int bar(int i, int j, int k);
}

class F : E
{
    extern (C++) int bar(int i, int j, int k)
    {
        printf("F.bar: i = %d\n", i);
        printf("F.bar: j = %d\n", j);
        printf("F.bar: k = %d\n", k);
        assert(i == 11);
        assert(j == 12);
        assert(k == 13);
        return 8;
    }
}

void test3()
{
    F f = new F();
    int i = callE(f);
    assert(i == 8);
}

static assert (callE.mangleof == "_Z5callEP1E");
static assert (E.bar.mangleof == "_ZN1E3barEiii");
static assert (F.bar.mangleof == "_ZN1F3barEiii");

/****************************************/

extern (C++) void foo4(char* p);

void test4()
{
    foo4(null);
}

static assert(foo4.mangleof == "_Z4foo4Pc");

/****************************************/

extern(C++)
{
  struct foo5 { int i; int j; void* p; }

  interface bar5{
    foo5 getFoo(int i);
  }

  bar5 newBar();
}

void test5()
{
  bar5 b = newBar();
  foo5 f = b.getFoo(4);
  printf("f.p = %p, b = %p\n", f.p, cast(void*)b);
  assert(f.p == cast(void*)b);
}

static assert(bar5.getFoo.mangleof == "_ZN4bar56getFooEi");
static assert (newBar.mangleof == "_Z6newBarv");

/****************************************/

extern(C++)
{
    struct S6
    {
        int i;
        double d;
    }
    S6 foo6();
}

extern (C) int foosize6();

void test6()
{
    S6 f = foo6();
    printf("%d %d\n", foosize6(), S6.sizeof);
    assert(foosize6() == S6.sizeof);
    assert(f.i == 42);
    printf("f.d = %g\n", f.d);
    assert(f.d == 2.5);
}

static assert (foo6.mangleof == "_Z4foo6v");

/****************************************/

extern (C) int foo7();

struct S
{
    int i;
    long l;
}

void test7()
{
    printf("%d %d\n", foo7(), S.sizeof);
    assert(foo7() == S.sizeof);
}

/****************************************/

extern (C++) void foo8(const char *);

void test8()
{
    char c;
    foo8(&c);
}

static assert(foo8.mangleof == "_Z4foo8PKc");

/****************************************/
// 4059

struct elem9 { }

extern(C++) void foobar9(elem9*, elem9*);

void test9()
{
    elem9 *a;
    foobar9(a, a);
}

static assert(foobar9.mangleof == "_Z7foobar9P5elem9S0_");

/****************************************/
// 5148

extern (C++)
{
    void foo10(const char*, const char*);
    void foo10(const int, const int);
    void foo10(const char, const char);

    struct MyStructType { }
    void foo10(const MyStructType s, const MyStructType t);

    enum MyEnumType { onemember }
    void foo10(const MyEnumType s, const MyEnumType t);
}

void test10()
{
    char* p;
    foo10(p, p);
    foo10(1,2);
    foo10('c','d');
    MyStructType s;
    foo10(s,s);
    MyEnumType e;
    foo10(e,e);
}

/**************************************/
// 10058

extern (C++)
{
    void test10058a(void*) { }
    void test10058b(void function(void*)) { }
    void test10058c(void* function(void*)) { }
    void test10058d(void function(void*), void*) { }
    void test10058e(void* function(void*), void*) { }
    void test10058f(void* function(void*), void* function(void*)) { }
    void test10058g(void function(void*), void*, void*) { }
    void test10058h(void* function(void*), void*, void*) { }
    void test10058i(void* function(void*), void* function(void*), void*) { }
    void test10058j(void* function(void*), void* function(void*), void* function(void*)) { }
    void test10058k(void* function(void*), void* function(const (void)*)) { }
    void test10058l(void* function(void*), void* function(const (void)*), const(void)* function(void*)) { }
}

static assert(test10058a.mangleof == "_Z10test10058aPv");
static assert(test10058b.mangleof == "_Z10test10058bPFvPvE");
static assert(test10058c.mangleof == "_Z10test10058cPFPvS_E");
static assert(test10058d.mangleof == "_Z10test10058dPFvPvES_");
static assert(test10058e.mangleof == "_Z10test10058ePFPvS_ES_");
static assert(test10058f.mangleof == "_Z10test10058fPFPvS_ES1_");
static assert(test10058g.mangleof == "_Z10test10058gPFvPvES_S_");
static assert(test10058h.mangleof == "_Z10test10058hPFPvS_ES_S_");
static assert(test10058i.mangleof == "_Z10test10058iPFPvS_ES1_S_");
static assert(test10058j.mangleof == "_Z10test10058jPFPvS_ES1_S1_");
static assert(test10058k.mangleof == "_Z10test10058kPFPvS_EPFS_PKvE");
static assert(test10058l.mangleof == "_Z10test10058lPFPvS_EPFS_PKvEPFS3_S_E");

/**************************************/
// 11696

class Expression;
struct Loc {}

extern(C++)
class CallExp
{
    static void test11696a(Loc, Expression, Expression);
    static void test11696b(Loc, Expression, Expression*);
    static void test11696c(Loc, Expression*, Expression);
    static void test11696d(Loc, Expression*, Expression*);
}

static assert(CallExp.test11696a.mangleof == "_ZN7CallExp10test11696aE3LocP10ExpressionS2_");
static assert(CallExp.test11696b.mangleof == "_ZN7CallExp10test11696bE3LocP10ExpressionPS2_");
static assert(CallExp.test11696c.mangleof == "_ZN7CallExp10test11696cE3LocPP10ExpressionS2_");
static assert(CallExp.test11696d.mangleof == "_ZN7CallExp10test11696dE3LocPP10ExpressionS3_");

/**************************************/
// 13337

extern(C++, N13337a.N13337b.N13337c)
{
  struct S13337{}
  void foo13337(S13337 s);
}

static assert(foo13337.mangleof == "_ZN7N13337a7N13337b7N13337c8foo13337ENS1_6S13337E");
