#include "calc.h"
#include "util.h"

int calc_add(int a, int b)
{
    return util_clamp(a + b, -1000, 1000);
}

int calc_mul(int a, int b)
{
    return util_clamp(a * b, -1000, 1000);
}
