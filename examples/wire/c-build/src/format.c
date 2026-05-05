#include <stdio.h>
#include "format.h"
#include "util.h"

void format_line(const char *label, int value)
{
    int clamped = util_clamp(value, -9999, 9999);
    printf("%s = %d\n", label, clamped);
}
