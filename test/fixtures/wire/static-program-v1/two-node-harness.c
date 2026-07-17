#include "program.h"

struct fixture_state {
  uint32_t first_dispatches;
  uint32_t second_dispatches;
  uint32_t cancellations;
};

static cortex_wire_program_v1_effect_result begin_effect(uint32_t node_id, void *context) {
  struct fixture_state *state = (struct fixture_state *)context;
  cortex_wire_program_v1_effect_result result;
  result.payload_handle = 0u;
  if (node_id == 0u) {
    state->first_dispatches += 1u;
    result.kind = CORTEX_WIRE_EFFECT_ACCEPTED_ASYNC;
  } else {
    state->second_dispatches += 1u;
    result.kind = CORTEX_WIRE_EFFECT_SUCCESS;
    result.payload_handle = 84u;
  }
  return result;
}

static void cancel_effect(uint32_t node_id, void *context) {
  struct fixture_state *state = (struct fixture_state *)context;
  (void)node_id;
  state->cancellations += 1u;
}

static int success_path(cortex_wire_program_v1_effect_api *api, struct fixture_state *state) {
  if (cortex_wire_program_v1_init(api) != 0) { return 10; }
  if (cortex_wire_program_v1_drive() != CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS) { return 11; }
  if (state->first_dispatches != 1u || state->second_dispatches != 0u) { return 12; }
  if (cortex_wire_program_v1_complete(0u, CORTEX_WIRE_EFFECT_SUCCESS, 42u) !=
      CORTEX_WIRE_COMPLETION_APPLIED) { return 13; }
  if (cortex_wire_program_v1_drive() != CORTEX_WIRE_DRIVE_COMPLETED) { return 14; }
  if (state->second_dispatches != 1u) { return 15; }
  if (cortex_wire_program_v1_output_handle(0u) != 42u ||
      cortex_wire_program_v1_output_handle(1u) != 84u) { return 16; }
  if (cortex_wire_program_v1_complete(0u, CORTEX_WIRE_EFFECT_SUCCESS, 0u) !=
      CORTEX_WIRE_COMPLETION_STALE) { return 17; }
  return 0;
}

static int failure_path(cortex_wire_program_v1_effect_api *api, struct fixture_state *state) {
  if (cortex_wire_program_v1_init(api) != 0) { return 20; }
  if (cortex_wire_program_v1_drive() != CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS) { return 21; }
  if (cortex_wire_program_v1_complete(0u, CORTEX_WIRE_EFFECT_FAILURE, 0u) !=
      CORTEX_WIRE_COMPLETION_APPLIED) { return 22; }
  if (cortex_wire_program_v1_drive() != CORTEX_WIRE_DRIVE_FAILED) { return 23; }
  if (state->second_dispatches != 0u) { return 24; }
  if (cortex_wire_program_v1_node_status(1u) != CORTEX_WIRE_STATUS_FAILED) { return 25; }
  return 0;
}

int main(int argc, char **argv) {
  struct fixture_state state = {0u, 0u, 0u};
  cortex_wire_program_v1_effect_api api = {begin_effect, cancel_effect, &state};
  if (argc != 2) { return 2; }
  if (argv[1][0] == 's' && argv[1][1] == '\0') { return success_path(&api, &state); }
  if (argv[1][0] == 'f' && argv[1][1] == '\0') { return failure_path(&api, &state); }
  return 2;
}
