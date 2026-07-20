#include "cortex_np_engine_b498f115caa07442.h"
#include "native_pure_region_0000.h"

#include <stdint.h>

static int expect_u32(uint32_t actual, uint32_t expected) {
  return actual == expected ? 0 : 1;
}

int main(void) {
  cortex_np_engine_b498f115caa07442_state state;
  /* score=40 -> mid=41; extra=100 exercises the `mid < extra` true branch. */
  native_pure_region_0000_input input = {.field_0 = 40, .field_1 = 100};
  native_pure_region_0000_output output = {0};

  if (expect_u32(cortex_np_engine_b498f115caa07442_init(&state), 0) != 0) {
    return 10;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &state, 0, &input, &output),
                 7) != 0) {
    return 11;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_checkpoint_committed(
                     &state, 2),
                 7) != 0) {
    return 12;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_checkpoint_committed(
                     &state, 1),
                 0) != 0) {
    return 13;
  }
  /* Independently hand-computed oracle: score=40 -> mid=41; 41 < 100, so the
     conditional's true branch selects mid (41), not extra (100). This is the
     only fixture that executes a generated two-input region through the
     checkpoint-gated engine, closing the previously untested De Bruijn
     multi-input variable-binding and conditional/comparison rendering path
     in Cortex.Wire.NativePure.Lean. */
  if (expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &state, 0, &input, &output),
                 0) != 0 ||
      output.value != 41 || state.checkpoint_sequence != 2 ||
      !state.awaiting_checkpoint) {
    return 14;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_can_request_effect(&state),
                 7) != 0) {
    return 15;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_checkpoint_committed(
                     &state, 2),
                 0) != 0 ||
      expect_u32(
          cortex_np_engine_b498f115caa07442_can_request_effect(&state), 0) !=
          0) {
    return 16;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_effect_completed(&state),
                 0) != 0 ||
      state.checkpoint_sequence != 3 || !state.awaiting_checkpoint) {
    return 17;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &state, 0, &input, &output),
                 7) != 0) {
    return 18;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_checkpoint_committed(
                     &state, 3),
                 0) != 0 ||
      expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &state, 99, &input, &output),
                 6) != 0) {
    return 19;
  }
  /* score=40 -> mid=41; extra=10 exercises the `mid < extra` false branch,
     independently proving both operands of the conditional and both
     De Bruijn-indexed inputs resolve to the correct values. */
  cortex_np_engine_b498f115caa07442_state falseBranchState;
  native_pure_region_0000_input falseBranchInput = {.field_0 = 40, .field_1 = 10};
  native_pure_region_0000_output falseBranchOutput = {0};
  if (expect_u32(cortex_np_engine_b498f115caa07442_init(&falseBranchState), 0) !=
          0 ||
      expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &falseBranchState, 0, &falseBranchInput, &falseBranchOutput),
                 7) != 0 ||
      expect_u32(cortex_np_engine_b498f115caa07442_checkpoint_committed(
                     &falseBranchState, 1),
                 0) != 0 ||
      expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &falseBranchState, 0, &falseBranchInput, &falseBranchOutput),
                 0) != 0 ||
      falseBranchOutput.value != 10) {
    return 22;
  }
  input.field_0 = INT64_MAX;
  if (expect_u32(cortex_np_engine_b498f115caa07442_dispatch(
                     &state, 0, &input, &output),
                 2) != 0 ||
      !state.failed || state.checkpoint_sequence != 4 ||
      !state.awaiting_checkpoint) {
    return 20;
  }
  if (expect_u32(cortex_np_engine_b498f115caa07442_checkpoint_committed(
                     &state, 4),
                 0) != 0 ||
      state.awaiting_checkpoint ||
      expect_u32(
          cortex_np_engine_b498f115caa07442_can_request_effect(&state), 7) !=
          0) {
    return 21;
  }
  return 0;
}
