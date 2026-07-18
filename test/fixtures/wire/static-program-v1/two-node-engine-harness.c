#include "program.h"

struct fixture_state {
  uint32_t first_requests;
  uint32_t second_requests;
  uint32_t cancellations;
};

static void request_effect(uint32_t node_id, void *context) {
  struct fixture_state *state = (struct fixture_state *)context;
  if (node_id == 0u) {
    state->first_requests += 1u;
  } else {
    state->second_requests += 1u;
  }
}

static void cancel_effect(uint32_t node_id, void *context) {
  struct fixture_state *state = (struct fixture_state *)context;
  (void)node_id;
  state->cancellations += 1u;
}

static int export_matches(
    uint64_t sequence,
    cortex_wire_engine_v1_terminal_state terminal,
    uint8_t first_status,
    uint8_t second_status,
    uint64_t first_handle,
    uint64_t second_handle) {
  cortex_wire_engine_v1_state_header header;
  uint8_t statuses[2] = {255u, 255u};
  uint64_t handles[2] = {99u, 99u};
  if (cortex_wire_engine_v1_export_state(&header, statuses, handles, 2u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 0;
  }
  return header.schema_version == CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION &&
         header.node_count == 2u &&
         header.checkpoint_sequence == sequence &&
         header.terminal == terminal &&
         statuses[0] == first_status &&
         statuses[1] == second_status &&
         handles[0] == first_handle &&
         handles[1] == second_handle;
}

static int fresh_success(
    cortex_wire_engine_v1_host_api *api,
    struct fixture_state *state) {
  if (cortex_wire_engine_v1_init(api) != 0) { return 10; }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED) {
    return 11;
  }
  if (!export_matches(
          1u,
          CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE,
          CORTEX_WIRE_STATUS_PENDING,
          CORTEX_WIRE_STATUS_PENDING,
          0u,
          0u)) {
    return 12;
  }
  if (cortex_wire_engine_v1_checkpoint_committed(2u) !=
      CORTEX_WIRE_ENGINE_STATE_INVALID) {
    return 13;
  }
  if (cortex_wire_engine_v1_checkpoint_committed(1u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 14;
  }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS) {
    return 15;
  }
  if (state->first_requests != 1u || state->second_requests != 0u) { return 16; }
  if (cortex_wire_engine_v1_complete(0u, CORTEX_WIRE_EFFECT_SUCCESS, 42u) !=
      CORTEX_WIRE_COMPLETION_APPLIED) {
    return 17;
  }
  if (cortex_wire_engine_v1_complete(0u, CORTEX_WIRE_EFFECT_SUCCESS, 42u) !=
      CORTEX_WIRE_COMPLETION_STALE) {
    return 18;
  }
  if (!export_matches(
          2u,
          CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE,
          CORTEX_WIRE_STATUS_COMPLETED,
          CORTEX_WIRE_STATUS_PENDING,
          42u,
          0u)) {
    return 19;
  }
  if (state->second_requests != 0u) { return 20; }
  if (cortex_wire_engine_v1_checkpoint_committed(2u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 21;
  }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS) {
    return 22;
  }
  if (state->second_requests != 1u) { return 23; }
  if (cortex_wire_engine_v1_complete(1u, CORTEX_WIRE_EFFECT_SUCCESS, 84u) !=
      CORTEX_WIRE_COMPLETION_APPLIED) {
    return 24;
  }
  if (cortex_wire_engine_v1_checkpoint_committed(3u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 25;
  }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED) {
    return 26;
  }
  if (!export_matches(
          4u,
          CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED,
          CORTEX_WIRE_STATUS_COMPLETED,
          CORTEX_WIRE_STATUS_COMPLETED,
          42u,
          84u)) {
    return 27;
  }
  if (cortex_wire_engine_v1_checkpoint_committed(4u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 28;
  }
  if (cortex_wire_engine_v1_drive() != CORTEX_WIRE_ENGINE_DRIVE_TERMINAL) {
    return 29;
  }
  if (cortex_wire_engine_v1_terminal() !=
      CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED) {
    return 30;
  }
  return 0;
}

static int restore_success(
    cortex_wire_engine_v1_host_api *api,
    struct fixture_state *state) {
  cortex_wire_engine_v1_state_header header = {
    CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION,
    2u,
    7u,
    CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE
  };
  uint8_t statuses[2] = {
    CORTEX_WIRE_STATUS_COMPLETED,
    CORTEX_WIRE_STATUS_PENDING
  };
  uint64_t handles[2] = {42u, 0u};
  if (cortex_wire_engine_v1_import_state(
          api,
          cortex_wire_engine_v1_program_identity(),
          &header,
          statuses,
          handles,
          2u) != CORTEX_WIRE_ENGINE_STATE_OK) {
    return 40;
  }
  if (!export_matches(
          7u,
          CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE,
          CORTEX_WIRE_STATUS_COMPLETED,
          CORTEX_WIRE_STATUS_PENDING,
          42u,
          0u)) {
    return 41;
  }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED) {
    return 42;
  }
  if (cortex_wire_engine_v1_checkpoint_committed(7u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 43;
  }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS) {
    return 44;
  }
  if (state->first_requests != 0u || state->second_requests != 1u) { return 45; }
  return 0;
}

static int restore_rejected(
    cortex_wire_engine_v1_host_api *api,
    char variant) {
  cortex_wire_engine_v1_state_header header = {
    CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION,
    2u,
    3u,
    CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE
  };
  uint8_t statuses[2] = {
    CORTEX_WIRE_STATUS_COMPLETED,
    CORTEX_WIRE_STATUS_PENDING
  };
  uint64_t handles[2] = {42u, 0u};
  const char *identity = cortex_wire_engine_v1_program_identity();
  cortex_wire_engine_v1_state_result expected = CORTEX_WIRE_ENGINE_STATE_INVALID;
  if (variant == 'i') {
    identity = "wrong-program";
    expected = CORTEX_WIRE_ENGINE_STATE_IDENTITY_MISMATCH;
  } else if (variant == 'n') {
    header.node_count = 3u;
  } else if (variant == 'h') {
    handles[0] = 0u;
  } else if (variant == 'd') {
    statuses[0] = CORTEX_WIRE_STATUS_PENDING;
    statuses[1] = CORTEX_WIRE_STATUS_COMPLETED;
    handles[0] = 0u;
    handles[1] = 84u;
  } else if (variant == 'r') {
    statuses[0] = CORTEX_WIRE_STATUS_RUNNING;
    handles[0] = 0u;
  } else if (variant == 't') {
    header.terminal = CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED;
  } else {
    return 59;
  }
  if (cortex_wire_engine_v1_import_state(
          api, identity, &header, statuses, handles, 2u) != expected) {
    return 60;
  }
  return 0;
}

static int cancellation(
    cortex_wire_engine_v1_host_api *api,
    struct fixture_state *state) {
  if (cortex_wire_engine_v1_init(api) != 0) { return 70; }
  if (cortex_wire_engine_v1_checkpoint_committed(1u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 71;
  }
  if (cortex_wire_engine_v1_drive() !=
      CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS) {
    return 72;
  }
  if (cortex_wire_engine_v1_cancel() != CORTEX_WIRE_ENGINE_STATE_OK) { return 73; }
  if (state->cancellations != 1u) { return 74; }
  if (!export_matches(
          2u,
          CORTEX_WIRE_ENGINE_TERMINAL_CANCELLED,
          CORTEX_WIRE_STATUS_PENDING,
          CORTEX_WIRE_STATUS_PENDING,
          0u,
          0u)) {
    return 75;
  }
  if (cortex_wire_engine_v1_checkpoint_committed(2u) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return 76;
  }
  if (cortex_wire_engine_v1_drive() != CORTEX_WIRE_ENGINE_DRIVE_TERMINAL) {
    return 77;
  }
  return 0;
}

int main(int argc, char **argv) {
  struct fixture_state state = {0u, 0u, 0u};
  cortex_wire_engine_v1_host_api api = {request_effect, cancel_effect, &state};
  if (argc != 2 || argv[1][1] != '\0') { return 2; }
  if (argv[1][0] == 's') { return fresh_success(&api, &state); }
  if (argv[1][0] == 'x') { return restore_success(&api, &state); }
  if (argv[1][0] == 'c') { return cancellation(&api, &state); }
  return restore_rejected(&api, argv[1][0]);
}
