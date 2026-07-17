/*
 * ADR 0091 three-way differential harness.
 *
 * Links against one generated `program.c` and replays scenarios from the shared
 * corpus emitted by `wire differential emit`. Each scenario line is driven
 * through the real generated ABI and reduced to the canonical trace line format
 * shared with the Haskell and Lean drivers, so the three trace streams can be
 * compared byte-for-byte.
 *
 * The harness also verifies the per-node exactly-once cancellation property: no
 * node may be cancelled more than once, and only a node that was actually
 * dispatched (marked running) may be cancelled at all.
 *
 * This is a host-only test harness: it uses stdio and is never linked into a
 * freestanding target image. Only `program.o` is subject to the freestanding
 * symbol and section audits.
 */
#include "program.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_NODES 64u
#define MAX_COMPLETIONS 256u
#define LINE_CAP 8192

struct scenario {
  char id[256];
  uint32_t node_count;
  uint32_t begin_kind[MAX_NODES];
  uint64_t begin_payload[MAX_NODES];
  uint32_t completion_count;
  uint32_t completion_node[MAX_COMPLETIONS];
  uint32_t completion_outcome[MAX_COMPLETIONS];
  uint64_t completion_payload[MAX_COMPLETIONS];
};

/* Effect and per-node dispatch/cancellation bookkeeping for the running run. */
struct run_context {
  const struct scenario *scenario;
  uint8_t dispatched[MAX_NODES];
  uint8_t cancel_count[MAX_NODES];
};

static cortex_wire_program_v1_effect_result differential_begin(uint32_t node_id, void *context) {
  struct run_context *ctx = (struct run_context *)context;
  cortex_wire_program_v1_effect_result result;
  result.payload_handle = 0u;
  result.kind = CORTEX_WIRE_EFFECT_FAILURE;
  if (node_id < ctx->scenario->node_count) {
    ctx->dispatched[node_id] = 1u;
    result.kind = (cortex_wire_program_v1_effect_kind)ctx->scenario->begin_kind[node_id];
    result.payload_handle = ctx->scenario->begin_payload[node_id];
  }
  return result;
}

static void differential_cancel(uint32_t node_id, void *context) {
  struct run_context *ctx = (struct run_context *)context;
  if (node_id < ctx->scenario->node_count) {
    ctx->cancel_count[node_id] += 1u;
  }
}

/* Parse a comma list of unsigned integers; returns the count, -1 on overflow. */
static int parse_u64_list(char *field, uint64_t *out, uint32_t cap) {
  uint32_t count = 0u;
  char *token;
  if (strcmp(field, "-") == 0) {
    return 0;
  }
  for (token = strtok(field, ","); token != NULL; token = strtok(NULL, ",")) {
    if (count >= cap) {
      return -1;
    }
    out[count] = strtoull(token, NULL, 10);
    count += 1u;
  }
  return (int)count;
}

static int parse_scenario(char *line, struct scenario *sc) {
  char *fields[6];
  char *cursor = line;
  int index;
  uint64_t begin_tmp[MAX_NODES];
  int begin_count;
  int payload_count;

  for (index = 0; index < 6; ++index) {
    char *space = strchr(cursor, ' ');
    if (index < 5) {
      if (space == NULL) {
        return -1;
      }
      *space = '\0';
      fields[index] = cursor;
      cursor = space + 1;
    } else {
      fields[index] = cursor;
    }
  }

  memset(sc, 0, sizeof(*sc));
  strncpy(sc->id, fields[0], sizeof(sc->id) - 1u);
  sc->node_count = (uint32_t)strtoul(fields[1], NULL, 10);
  if (sc->node_count > MAX_NODES) {
    return -1;
  }

  /* fields[2] holds control edges; the generated program already encodes the
   * topology, so the harness does not re-parse it. */

  begin_count = parse_u64_list(fields[3], begin_tmp, MAX_NODES);
  if (begin_count < 0 || (uint32_t)begin_count != sc->node_count) {
    return -1;
  }
  for (index = 0; index < begin_count; ++index) {
    sc->begin_kind[index] = (uint32_t)begin_tmp[index];
  }

  payload_count = parse_u64_list(fields[4], sc->begin_payload, MAX_NODES);
  if (payload_count < 0 || (uint32_t)payload_count != sc->node_count) {
    return -1;
  }

  sc->completion_count = 0u;
  if (strcmp(fields[5], "-") != 0) {
    char *token;
    for (token = strtok(fields[5], ","); token != NULL; token = strtok(NULL, ",")) {
      unsigned long node;
      unsigned long outcome;
      unsigned long long payload;
      if (sc->completion_count >= MAX_COMPLETIONS) {
        return -1;
      }
      if (sscanf(token, "%lu:%lu:%llu", &node, &outcome, &payload) != 3) {
        return -1;
      }
      sc->completion_node[sc->completion_count] = (uint32_t)node;
      sc->completion_outcome[sc->completion_count] = (uint32_t)outcome;
      sc->completion_payload[sc->completion_count] = (uint64_t)payload;
      sc->completion_count += 1u;
    }
  }
  return 0;
}

static void append_status_vector(char *buffer, size_t cap, uint32_t node_count) {
  uint32_t node_id;
  size_t len = strlen(buffer);
  for (node_id = 0u; node_id < node_count; ++node_id) {
    int written = snprintf(
        buffer + len,
        cap - len,
        "%s%u",
        node_id == 0u ? "" : ",",
        (unsigned)cortex_wire_program_v1_node_status(node_id));
    if (written < 0) {
      return;
    }
    len += (size_t)written;
  }
}

static void append_output_vector(char *buffer, size_t cap, uint32_t node_count) {
  uint32_t node_id;
  size_t len = strlen(buffer);
  for (node_id = 0u; node_id < node_count; ++node_id) {
    int written;
    cortex_wire_program_v1_status status = cortex_wire_program_v1_node_status(node_id);
    if (status == CORTEX_WIRE_STATUS_COMPLETED) {
      written = snprintf(
          buffer + len,
          cap - len,
          "%s%llu",
          node_id == 0u ? "" : ",",
          (unsigned long long)cortex_wire_program_v1_output_handle(node_id));
    } else {
      written = snprintf(buffer + len, cap - len, "%sn", node_id == 0u ? "" : ",");
    }
    if (written < 0) {
      return;
    }
    len += (size_t)written;
  }
}

/*
 * Replay one scenario. The loop mirrors the reference driver: drive, and while a
 * drive reports awaiting consume the next completion; once a drive settles the
 * run, deliver any remaining completions (observing their post-terminal
 * rejection) but do not drive again.
 */
static int run_scenario(const struct scenario *sc, char *trace, size_t cap) {
  struct run_context ctx;
  cortex_wire_program_v1_effect_api api;
  uint32_t next_completion = 0u;
  int terminal = -1;
  int first_step = 1;

  memset(&ctx, 0, sizeof(ctx));
  ctx.scenario = sc;
  api.effect_begin = differential_begin;
  api.effect_cancel = differential_cancel;
  api.context = &ctx;

  if (cortex_wire_program_v1_node_count() != sc->node_count) {
    fprintf(stderr, "node count mismatch for %s\n", sc->id);
    return -1;
  }
  if (cortex_wire_program_v1_init(&api) != 0) {
    fprintf(stderr, "init failed for %s\n", sc->id);
    return -1;
  }

  snprintf(trace, cap, "%s\t", sc->id);

  for (;;) {
    cortex_wire_program_v1_drive_result result = cortex_wire_program_v1_drive();
    size_t len = strlen(trace);
    snprintf(trace + len, cap - len, "%sD%u:", first_step ? "" : " ", (unsigned)result);
    first_step = 0;
    append_status_vector(trace, cap, sc->node_count);
    len = strlen(trace);
    snprintf(trace + len, cap - len, ":");
    append_output_vector(trace, cap, sc->node_count);

    if (result == CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS && next_completion < sc->completion_count) {
      uint32_t idx = next_completion;
      cortex_wire_program_v1_completion_result cr = cortex_wire_program_v1_complete(
          sc->completion_node[idx],
          (cortex_wire_program_v1_effect_kind)sc->completion_outcome[idx],
          sc->completion_payload[idx]);
      len = strlen(trace);
      snprintf(
          trace + len,
          cap - len,
          " C%u,%u,%llu:%u",
          (unsigned)sc->completion_node[idx],
          (unsigned)sc->completion_outcome[idx],
          (unsigned long long)sc->completion_payload[idx],
          (unsigned)cr);
      next_completion += 1u;
      continue;
    }

    if (result == CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS) {
      terminal = (int)result;
      break;
    }

    /* Terminal drive: deliver remaining completions as post-terminal events. */
    terminal = (int)result;
    while (next_completion < sc->completion_count) {
      uint32_t idx = next_completion;
      cortex_wire_program_v1_completion_result cr = cortex_wire_program_v1_complete(
          sc->completion_node[idx],
          (cortex_wire_program_v1_effect_kind)sc->completion_outcome[idx],
          sc->completion_payload[idx]);
      len = strlen(trace);
      snprintf(
          trace + len,
          cap - len,
          " C%u,%u,%llu:%u",
          (unsigned)sc->completion_node[idx],
          (unsigned)sc->completion_outcome[idx],
          (unsigned long long)sc->completion_payload[idx],
          (unsigned)cr);
      next_completion += 1u;
    }
    break;
  }

  /* Exactly-once cancellation invariant. */
  {
    uint32_t node_id;
    for (node_id = 0u; node_id < sc->node_count; ++node_id) {
      if (ctx.cancel_count[node_id] > 1u) {
        fprintf(stderr, "node %u cancelled %u times in %s\n", node_id, ctx.cancel_count[node_id], sc->id);
        return -1;
      }
      if (ctx.cancel_count[node_id] == 1u && ctx.dispatched[node_id] == 0u) {
        fprintf(stderr, "node %u cancelled without dispatch in %s\n", node_id, sc->id);
        return -1;
      }
    }
  }

  {
    size_t len = strlen(trace);
    snprintf(trace + len, cap - len, "\t%d\t", terminal);
    append_status_vector(trace, cap, sc->node_count);
    len = strlen(trace);
    snprintf(trace + len, cap - len, "\t");
    append_output_vector(trace, cap, sc->node_count);
  }
  return 0;
}

/*
 * The generated ABI latches `initialized` and refuses re-init, so each process
 * replays exactly one scenario: either argv[1] or a single line read from stdin.
 * The Nix check loops the corpus one scenario per invocation.
 */
int main(int argc, char **argv) {
  char line[LINE_CAP];
  char trace[LINE_CAP * 2];
  struct scenario sc;
  char *source;
  size_t len;

  if (argc == 2) {
    strncpy(line, argv[1], sizeof(line) - 1u);
    line[sizeof(line) - 1u] = '\0';
    source = line;
  } else if (argc == 1) {
    if (fgets(line, sizeof(line), stdin) == NULL) {
      return 0;
    }
    source = line;
  } else {
    fprintf(stderr, "usage: differential-harness [SCENARIO_LINE]\n");
    return 2;
  }

  len = strlen(source);
  if (len > 0u && source[len - 1u] == '\n') {
    source[len - 1u] = '\0';
  }
  if (source[0] == '\0') {
    return 0;
  }
  if (parse_scenario(source, &sc) != 0) {
    fprintf(stderr, "failed to parse scenario line\n");
    return 1;
  }
  trace[0] = '\0';
  if (run_scenario(&sc, trace, sizeof(trace)) != 0) {
    return 1;
  }
  printf("%s\n", trace);
  return 0;
}
