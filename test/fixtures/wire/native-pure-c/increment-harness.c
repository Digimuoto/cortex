#include "increment.h"

#include <limits.h>
#include <stdint.h>

int main(void) {
  increment_input input = {.field_0 = 41};
  increment_output output = {0};
  if (increment_run(&input, &output) != CORTEX_NP_OK || output.value != 42) {
    return 1;
  }
  input.field_0 = INT64_MAX;
  if (increment_run(&input, &output) != CORTEX_NP_ARITHMETIC_OVERFLOW) {
    return 2;
  }
  return 0;
}
