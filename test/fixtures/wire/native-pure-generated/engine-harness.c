#include "cortex_np_engine_dd728d0ed625b900.h"
#include "native_pure_region_0000.h"

#include <stdint.h>

static int expect_u32(uint32_t actual, uint32_t expected) {
  return actual == expected ? 0 : 1;
}

int main(void) {
  cortex_np_engine_dd728d0ed625b900_state state;
  native_pure_region_0000_input input = {.field_0 = 40};
  native_pure_region_0000_output output = {.value = 0};

  if (expect_u32(cortex_np_engine_dd728d0ed625b900_init(&state), 0) != 0) {
    return 10;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_dispatch(
                     &state, 0, &input, &output),
                 7) != 0) {
    return 11;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_checkpoint_committed(
                     &state, 2),
                 7) != 0) {
    return 12;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_checkpoint_committed(
                     &state, 1),
                 0) != 0) {
    return 13;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_dispatch(
                     &state, 0, &input, &output),
                 0) != 0 ||
      output.value != 42 || state.checkpoint_sequence != 2 ||
      !state.awaiting_checkpoint) {
    return 14;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_can_request_effect(&state),
                 7) != 0) {
    return 15;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_checkpoint_committed(
                     &state, 2),
                 0) != 0 ||
      expect_u32(
          cortex_np_engine_dd728d0ed625b900_can_request_effect(&state), 0) !=
          0) {
    return 16;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_effect_completed(&state),
                 0) != 0 ||
      state.checkpoint_sequence != 3 || !state.awaiting_checkpoint) {
    return 17;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_dispatch(
                     &state, 0, &input, &output),
                 7) != 0) {
    return 18;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_checkpoint_committed(
                     &state, 3),
                 0) != 0 ||
      expect_u32(cortex_np_engine_dd728d0ed625b900_dispatch(
                     &state, 99, &input, &output),
                 6) != 0) {
    return 19;
  }
  input.field_0 = INT64_MAX;
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_dispatch(
                     &state, 0, &input, &output),
                 2) != 0 ||
      !state.failed || state.checkpoint_sequence != 4 ||
      !state.awaiting_checkpoint) {
    return 20;
  }
  if (expect_u32(cortex_np_engine_dd728d0ed625b900_checkpoint_committed(
                     &state, 4),
                 0) != 0 ||
      state.awaiting_checkpoint ||
      expect_u32(
          cortex_np_engine_dd728d0ed625b900_can_request_effect(&state), 7) !=
          0) {
    return 21;
  }
  return 0;
}
