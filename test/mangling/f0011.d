extern(C++):

void foo(void* function (void*),void* function (const(void)*),const(void)* function (void*));
static assert(foo.mangleof == "_Z3fooPFPvS_EPFS_PKvEPFS3_S_E");
