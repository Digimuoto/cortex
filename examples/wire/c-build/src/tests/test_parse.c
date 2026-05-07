#include "parse.h"

#include <assert.h>

int main(void)
{
    int values[4] = {0, 0, 0, 0};
    size_t count = parse_int_list("9, 2, 6", values, 4);

    assert(count == 3);
    assert(values[0] == 9);
    assert(values[1] == 2);
    assert(values[2] == 6);

    return 0;
}
