#include "parse.h"

#include <errno.h>
#include <stdlib.h>

size_t parse_int_list(const char *input, int *output, size_t capacity)
{
    if (input == 0 || output == 0 || capacity == 0) {
        return 0;
    }

    const char *cursor = input;
    size_t count = 0;

    while (*cursor != '\0' && count < capacity) {
        char *next = 0;
        errno = 0;
        long parsed = strtol(cursor, &next, 10);

        if (cursor == next || errno != 0) {
            break;
        }

        output[count] = (int)parsed;
        count++;
        cursor = next;

        while (*cursor == ',' || *cursor == ' ') {
            cursor++;
        }
    }

    return count;
}
