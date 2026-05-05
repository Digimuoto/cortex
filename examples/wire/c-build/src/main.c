#include "calc.h"
#include "format.h"

int main(void)
{
    format_line("sum", calc_add(2, 3));
    format_line("product", calc_mul(4, 5));
    return 0;
}
