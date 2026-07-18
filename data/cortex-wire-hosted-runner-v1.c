#include "program.h"

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CORTEX_PROTOCOL "cortex.wire.host-process/v1"
#define CORTEX_ENGINE_ABI "cortex.wire.engine/v1"
#define CORTEX_STATE_SCHEMA "cortex.wire.engine-state/v1"
#define CORTEX_MAX_LINE_BYTES (2u * 1024u * 1024u)
#define CORTEX_MAX_NODES 32768u
#define CORTEX_MAX_RUN_ID 128u
#define CORTEX_MAX_REASON 512u

static char run_id[CORTEX_MAX_RUN_ID + 1u];
static uint8_t run_started;
static uint8_t terminal_emitted;
static uint8_t runner_fault;
static uint64_t next_request_sequence = 1u;
static uint64_t *request_sequences;
static uint8_t *snapshot_statuses;
static uint64_t *snapshot_handles;
static uint32_t node_count;

static void write_json_string(const char *value) {
  const unsigned char *cursor = (const unsigned char *)value;
  fputc('"', stdout);
  while (*cursor != 0u) {
    unsigned char current = *cursor;
    if (current == '"' || current == '\\') {
      fputc('\\', stdout);
      fputc((int)current, stdout);
    } else if (current == '\n') {
      fputs("\\n", stdout);
    } else if (current == '\r') {
      fputs("\\r", stdout);
    } else if (current == '\t') {
      fputs("\\t", stdout);
    } else if (current < 32u) {
      fputs("\\u001f", stdout);
    } else {
      fputc((int)current, stdout);
    }
    ++cursor;
  }
  fputc('"', stdout);
}

static int fail_protocol(const char *message) {
  fputs("{\"type\":\"protocol_error\",\"protocol\":\"" CORTEX_PROTOCOL
        "\",\"run_id\":", stdout);
  if (run_started != 0u) {
    write_json_string(run_id);
  } else {
    fputs("null", stdout);
  }
  fputs(",\"message\":", stdout);
  write_json_string(message);
  fputs("}\n", stdout);
  fflush(stdout);
  fprintf(stderr, "cortex hosted runner: %s\n", message);
  runner_fault = 1u;
  return 0;
}

static const char *find_value(const char *line, const char *key) {
  char pattern[96];
  const char *match;
  const char *cursor;
  int written = snprintf(pattern, sizeof(pattern), "\"%s\"", key);
  if (written < 0 || (size_t)written >= sizeof(pattern)) { return NULL; }
  match = strstr(line, pattern);
  if (match == NULL || strstr(match + strlen(pattern), pattern) != NULL) { return NULL; }
  cursor = match + strlen(pattern);
  while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
  if (*cursor != ':') { return NULL; }
  ++cursor;
  while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
  return cursor;
}

static int parse_string(
    const char *line,
    const char *key,
    char *output,
    size_t capacity) {
  const char *cursor = find_value(line, key);
  size_t length = 0u;
  if (cursor == NULL || *cursor != '"' || capacity == 0u) { return 0; }
  ++cursor;
  while (*cursor != 0 && *cursor != '"') {
    unsigned char current = (unsigned char)*cursor;
    if (current == '\\' || current < 32u || length + 1u >= capacity) { return 0; }
    output[length] = (char)current;
    ++length;
    ++cursor;
  }
  if (*cursor != '"') { return 0; }
  output[length] = '\0';
  return 1;
}

static int parse_u64_value(const char *cursor, uint64_t *output, const char **end) {
  char *parsed_end;
  unsigned long long value;
  if (cursor == NULL || isdigit((unsigned char)*cursor) == 0) { return 0; }
  errno = 0;
  value = strtoull(cursor, &parsed_end, 10);
  if (errno != 0 || parsed_end == cursor) { return 0; }
  *output = (uint64_t)value;
  if (end != NULL) { *end = parsed_end; }
  return 1;
}

static int parse_u64(const char *line, const char *key, uint64_t *output) {
  const char *end;
  if (!parse_u64_value(find_value(line, key), output, &end)) { return 0; }
  while (isspace((unsigned char)*end) != 0) { ++end; }
  return *end == ',' || *end == '}' || *end == ']';
}

static int parse_u32(const char *line, const char *key, uint32_t *output) {
  uint64_t value;
  if (!parse_u64(line, key, &value) || value > UINT32_MAX) { return 0; }
  *output = (uint32_t)value;
  return 1;
}

static int status_from_text(const char *value, uint8_t *status) {
  if (strcmp(value, "pending") == 0) {
    *status = CORTEX_WIRE_STATUS_PENDING;
  } else if (strcmp(value, "running") == 0) {
    *status = CORTEX_WIRE_STATUS_RUNNING;
  } else if (strcmp(value, "completed") == 0) {
    *status = CORTEX_WIRE_STATUS_COMPLETED;
  } else if (strcmp(value, "failed") == 0) {
    *status = CORTEX_WIRE_STATUS_FAILED;
  } else if (strcmp(value, "skipped") == 0) {
    *status = CORTEX_WIRE_STATUS_SKIPPED;
  } else {
    return 0;
  }
  return 1;
}

static const char *status_text(uint8_t status) {
  switch (status) {
    case CORTEX_WIRE_STATUS_PENDING: return "pending";
    case CORTEX_WIRE_STATUS_RUNNING: return "running";
    case CORTEX_WIRE_STATUS_COMPLETED: return "completed";
    case CORTEX_WIRE_STATUS_FAILED: return "failed";
    case CORTEX_WIRE_STATUS_SKIPPED: return "skipped";
    default: return NULL;
  }
}

static int terminal_from_text(
    const char *value,
    cortex_wire_engine_v1_terminal_state *terminal) {
  if (strcmp(value, "active") == 0) {
    *terminal = CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE;
  } else if (strcmp(value, "completed") == 0) {
    *terminal = CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED;
  } else if (strcmp(value, "failed") == 0) {
    *terminal = CORTEX_WIRE_ENGINE_TERMINAL_FAILED;
  } else if (strcmp(value, "cancelled") == 0) {
    *terminal = CORTEX_WIRE_ENGINE_TERMINAL_CANCELLED;
  } else {
    return 0;
  }
  return 1;
}

static const char *terminal_text(cortex_wire_engine_v1_terminal_state terminal) {
  switch (terminal) {
    case CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE: return "active";
    case CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED: return "completed";
    case CORTEX_WIRE_ENGINE_TERMINAL_FAILED: return "failed";
    case CORTEX_WIRE_ENGINE_TERMINAL_CANCELLED: return "cancelled";
    default: return NULL;
  }
}

static int parse_status_array(const char *line, uint8_t *statuses, uint32_t count) {
  const char *cursor = find_value(line, "node_statuses");
  uint32_t index;
  if (cursor == NULL || *cursor != '[') { return 0; }
  ++cursor;
  for (index = 0u; index < count; ++index) {
    char value[16];
    size_t length = 0u;
    while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
    if (index != 0u) {
      if (*cursor != ',') { return 0; }
      ++cursor;
      while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
    }
    if (*cursor != '"') { return 0; }
    ++cursor;
    while (*cursor != 0 && *cursor != '"' && length + 1u < sizeof(value)) {
      value[length] = *cursor;
      ++length;
      ++cursor;
    }
    if (*cursor != '"') { return 0; }
    ++cursor;
    value[length] = '\0';
    if (!status_from_text(value, &statuses[index])) { return 0; }
  }
  while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
  return *cursor == ']';
}

static int parse_handle_array(const char *line, uint64_t *handles, uint32_t count) {
  const char *cursor = find_value(line, "output_handles");
  uint32_t index;
  if (cursor == NULL || *cursor != '[') { return 0; }
  ++cursor;
  for (index = 0u; index < count; ++index) {
    while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
    if (index != 0u) {
      if (*cursor != ',') { return 0; }
      ++cursor;
      while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
    }
    if (!parse_u64_value(cursor, &handles[index], &cursor)) { return 0; }
  }
  while (isspace((unsigned char)*cursor) != 0) { ++cursor; }
  return *cursor == ']';
}

static int require_protocol(const char *line) {
  char protocol[64];
  return parse_string(line, "protocol", protocol, sizeof(protocol)) &&
         strcmp(protocol, CORTEX_PROTOCOL) == 0;
}

static int require_run_id(const char *line) {
  char candidate[CORTEX_MAX_RUN_ID + 1u];
  return parse_string(line, "run_id", candidate, sizeof(candidate)) &&
         strcmp(candidate, run_id) == 0;
}

static void emit_hello(void) {
  fputs("{\"type\":\"hello\",\"protocol\":\"" CORTEX_PROTOCOL
        "\",\"program_identity\":", stdout);
  write_json_string(cortex_wire_engine_v1_program_identity());
  fputs(",\"engine_abi\":\"" CORTEX_ENGINE_ABI "\"}\n", stdout);
  fflush(stdout);
}

static void emit_effect_requested(uint32_t node_id, void *context) {
  uint64_t sequence;
  (void)context;
  if (node_id >= node_count || request_sequences[node_id] != 0u) {
    runner_fault = 1u;
    return;
  }
  sequence = next_request_sequence;
  ++next_request_sequence;
  request_sequences[node_id] = sequence;
  fputs("{\"type\":\"effect_requested\",\"protocol\":\"" CORTEX_PROTOCOL
        "\",\"run_id\":", stdout);
  write_json_string(run_id);
  fprintf(stdout, ",\"sequence\":%llu,\"node_id\":%u}\n",
          (unsigned long long)sequence, node_id);
  fflush(stdout);
}

static void cancel_effect(uint32_t node_id, void *context) {
  (void)context;
  if (node_id < node_count) { request_sequences[node_id] = 0u; }
}

static int emit_checkpoint(void) {
  cortex_wire_engine_v1_state_header header;
  uint32_t node_id;
  const char *terminal;
  if (cortex_wire_engine_v1_export_state(
          &header, snapshot_statuses, snapshot_handles, node_count) !=
      CORTEX_WIRE_ENGINE_STATE_OK) {
    return fail_protocol("engine state export failed");
  }
  terminal = terminal_text(header.terminal);
  if (terminal == NULL) { return fail_protocol("engine exported invalid terminal state"); }
  fputs("{\"type\":\"checkpoint\",\"protocol\":\"" CORTEX_PROTOCOL
        "\",\"run_id\":", stdout);
  write_json_string(run_id);
  fputs(",\"state\":{\"schema\":\"" CORTEX_STATE_SCHEMA
        "\",\"program_identity\":", stdout);
  write_json_string(cortex_wire_engine_v1_program_identity());
  fprintf(stdout, ",\"checkpoint_sequence\":%llu,\"terminal\":\"%s\","
          "\"node_statuses\":[",
          (unsigned long long)header.checkpoint_sequence, terminal);
  for (node_id = 0u; node_id < node_count; ++node_id) {
    const char *status = status_text(snapshot_statuses[node_id]);
    if (status == NULL) { return fail_protocol("engine exported invalid node status"); }
    if (node_id != 0u) { fputc(',', stdout); }
    fprintf(stdout, "\"%s\"", status);
  }
  fputs("],\"output_handles\":[", stdout);
  for (node_id = 0u; node_id < node_count; ++node_id) {
    if (node_id != 0u) { fputc(',', stdout); }
    fprintf(stdout, "%llu", (unsigned long long)snapshot_handles[node_id]);
  }
  fputs("]}}\n", stdout);
  fflush(stdout);
  return 1;
}

static int emit_terminal(void) {
  const char *terminal = terminal_text(cortex_wire_engine_v1_terminal());
  if (terminal == NULL || strcmp(terminal, "active") == 0) {
    return fail_protocol("engine reported invalid terminal transition");
  }
  fputs("{\"type\":\"terminal\",\"protocol\":\"" CORTEX_PROTOCOL
        "\",\"run_id\":", stdout);
  write_json_string(run_id);
  fprintf(stdout, ",\"terminal\":\"%s\"}\n", terminal);
  fflush(stdout);
  terminal_emitted = 1u;
  return 1;
}

static int drive_and_emit(void) {
  cortex_wire_engine_v1_drive_result result = cortex_wire_engine_v1_drive();
  if (runner_fault != 0u) { return fail_protocol("effect request state violation"); }
  switch (result) {
    case CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED: return emit_checkpoint();
    case CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS: return 1;
    case CORTEX_WIRE_ENGINE_DRIVE_TERMINAL: return emit_terminal();
    case CORTEX_WIRE_ENGINE_DRIVE_STUCK: return fail_protocol("engine became stuck");
    case CORTEX_WIRE_ENGINE_DRIVE_ABI_ERROR: return fail_protocol("engine ABI error");
    default: return fail_protocol("engine returned an unknown drive result");
  }
}

static int begin_fresh(const char *line, cortex_wire_engine_v1_host_api *api) {
  if (run_started != 0u ||
      !parse_string(line, "run_id", run_id, sizeof(run_id)) ||
      run_id[0] == '\0') {
    return fail_protocol("invalid start command");
  }
  run_started = 1u;
  if (cortex_wire_engine_v1_init(api) != 0) {
    return fail_protocol("engine initialization failed");
  }
  return emit_checkpoint();
}

static int begin_restore(const char *line, cortex_wire_engine_v1_host_api *api) {
  cortex_wire_engine_v1_state_header header;
  char schema[64];
  char identity[256];
  char terminal[32];
  if (run_started != 0u ||
      !parse_string(line, "run_id", run_id, sizeof(run_id)) ||
      run_id[0] == '\0' ||
      !parse_string(line, "schema", schema, sizeof(schema)) ||
      strcmp(schema, CORTEX_STATE_SCHEMA) != 0 ||
      !parse_string(line, "program_identity", identity, sizeof(identity)) ||
      !parse_u64(line, "checkpoint_sequence", &header.checkpoint_sequence) ||
      !parse_string(line, "terminal", terminal, sizeof(terminal)) ||
      !terminal_from_text(terminal, &header.terminal) ||
      !parse_status_array(line, snapshot_statuses, node_count) ||
      !parse_handle_array(line, snapshot_handles, node_count)) {
    return fail_protocol("invalid restore command");
  }
  header.schema_version = CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION;
  header.node_count = node_count;
  run_started = 1u;
  if (cortex_wire_engine_v1_import_state(
          api,
          identity,
          &header,
          snapshot_statuses,
          snapshot_handles,
          node_count) != CORTEX_WIRE_ENGINE_STATE_OK) {
    return fail_protocol("engine rejected restored state");
  }
  return emit_checkpoint();
}

static int complete_effect(const char *line) {
  char outcome[32];
  uint64_t sequence;
  uint64_t handle;
  uint32_t node_id;
  cortex_wire_program_v1_effect_kind kind;
  cortex_wire_program_v1_completion_result result;
  if (!parse_u64(line, "sequence", &sequence) ||
      !parse_u32(line, "node_id", &node_id) ||
      !parse_string(line, "outcome", outcome, sizeof(outcome)) ||
      !parse_u64(line, "output_handle", &handle) ||
      node_id >= node_count ||
      request_sequences[node_id] != sequence) {
    return fail_protocol("stale or malformed effect completion");
  }
  if (strcmp(outcome, "success") == 0 && handle != 0u) {
    kind = CORTEX_WIRE_EFFECT_SUCCESS;
  } else if (strcmp(outcome, "skipped") == 0 && handle == 0u) {
    kind = CORTEX_WIRE_EFFECT_SKIPPED;
  } else if (strcmp(outcome, "failure") == 0 && handle == 0u) {
    kind = CORTEX_WIRE_EFFECT_FAILURE;
  } else {
    return fail_protocol("invalid effect completion outcome");
  }
  result = cortex_wire_engine_v1_complete(node_id, kind, handle);
  if (result != CORTEX_WIRE_COMPLETION_APPLIED) {
    return fail_protocol("engine rejected effect completion");
  }
  request_sequences[node_id] = 0u;
  return emit_checkpoint();
}

static int commit_checkpoint(const char *line) {
  uint64_t sequence;
  if (!parse_u64(line, "sequence", &sequence) ||
      cortex_wire_engine_v1_checkpoint_committed(sequence) !=
        CORTEX_WIRE_ENGINE_STATE_OK) {
    return fail_protocol("invalid checkpoint acknowledgement");
  }
  return drive_and_emit();
}

static int cancel_run(const char *line) {
  char reason[CORTEX_MAX_REASON + 1u];
  uint32_t node_id;
  if (!parse_string(line, "reason", reason, sizeof(reason))) {
    return fail_protocol("invalid cancel command");
  }
  if (cortex_wire_engine_v1_cancel() != CORTEX_WIRE_ENGINE_STATE_OK) {
    return fail_protocol("engine rejected cancellation");
  }
  for (node_id = 0u; node_id < node_count; ++node_id) {
    request_sequences[node_id] = 0u;
  }
  return emit_checkpoint();
}

static int dispatch_command(
    const char *line,
    cortex_wire_engine_v1_host_api *api) {
  char type[48];
  if (!require_protocol(line) || !parse_string(line, "type", type, sizeof(type))) {
    return fail_protocol("malformed or version-mismatched host command");
  }
  if (strcmp(type, "start") == 0) { return begin_fresh(line, api); }
  if (strcmp(type, "restore") == 0) { return begin_restore(line, api); }
  if (run_started == 0u || !require_run_id(line)) {
    return fail_protocol("host command run correlation mismatch");
  }
  if (terminal_emitted != 0u) {
    if (strcmp(type, "shutdown") == 0) { return 2; }
    return fail_protocol("unexpected command after terminal event");
  }
  if (strcmp(type, "effect_completed") == 0) { return complete_effect(line); }
  if (strcmp(type, "checkpoint_committed") == 0) {
    return commit_checkpoint(line);
  }
  if (strcmp(type, "cancel") == 0) { return cancel_run(line); }
  if (strcmp(type, "shutdown") == 0) {
    return fail_protocol("shutdown requires a terminal event");
  }
  return fail_protocol("unexpected host command");
}

int main(void) {
  char *line;
  cortex_wire_engine_v1_host_api api;
  int exit_code = 1;
  node_count = cortex_wire_program_v1_node_count();
  if (node_count > CORTEX_MAX_NODES) {
    fail_protocol("program exceeds hosted runner node bound");
    return 1;
  }
  request_sequences = (uint64_t *)calloc(node_count == 0u ? 1u : node_count, sizeof(uint64_t));
  snapshot_statuses = (uint8_t *)calloc(node_count == 0u ? 1u : node_count, sizeof(uint8_t));
  snapshot_handles = (uint64_t *)calloc(node_count == 0u ? 1u : node_count, sizeof(uint64_t));
  line = (char *)malloc(CORTEX_MAX_LINE_BYTES + 1u);
  if (request_sequences == NULL || snapshot_statuses == NULL ||
      snapshot_handles == NULL || line == NULL) {
    fail_protocol("runner allocation failed");
    goto cleanup;
  }
  api.effect_request = emit_effect_requested;
  api.effect_cancel = cancel_effect;
  api.context = NULL;
  emit_hello();
  while (fgets(line, (int)CORTEX_MAX_LINE_BYTES + 1, stdin) != NULL) {
    size_t length = strlen(line);
    int result;
    if (length == 0u || line[length - 1u] != '\n') {
      fail_protocol("oversized or unterminated JSONL command");
      goto cleanup;
    }
    result = dispatch_command(line, &api);
    if (result == 2) {
      exit_code = 0;
      goto cleanup;
    }
    if (result == 0 || runner_fault != 0u) { goto cleanup; }
  }
  if (terminal_emitted != 0u) { exit_code = 0; }

cleanup:
  free(line);
  free(snapshot_handles);
  free(snapshot_statuses);
  free(request_sequences);
  return exit_code;
}
