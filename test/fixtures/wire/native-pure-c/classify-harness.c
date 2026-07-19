#include "classify.h"

#include <stdint.h>

int main(void) {
  classify_input input = {.field_0 = -7};
  classify_output output = {0};
  if (classify_run(&input, &output) != CORTEX_NP_OK ||
      output.value.tag != 1 || output.value.payload.variant_1 != -7) {
    return 1;
  }
  input.field_0 = 9;
  if (classify_run(&input, &output) != CORTEX_NP_OK ||
      output.value.tag != 0 || output.value.payload.variant_0 != 9) {
    return 2;
  }
  return 0;
}
