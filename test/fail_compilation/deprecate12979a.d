// REQUIRED_ARGS: -de
// PERMUTE_ARGS:

/*
TEST_OUTPUT:
---
fail_compilation/deprecate12979a.d(14): Deprecation: asm statement is assumed to throw - mark it with 'nothrow' if it does not
fail_compilation/deprecate12979a.d(12): Error: function 'deprecate12979a.foo' is nothrow yet may throw
---
*/

void foo() nothrow
{
    asm
    {
        ret;
    }
}
