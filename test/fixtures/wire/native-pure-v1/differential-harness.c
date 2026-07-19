/* NativePure Haskell/Lean/generated-C differential harness. */
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  int64_t field_0;
} increment_input;
typedef struct {
  int64_t value;
} increment_output;
extern uint32_t increment_run(const increment_input *, increment_output *);

typedef union {
  int64_t variant_0;
  int64_t variant_1;
} classify_payload;
typedef struct {
  uint32_t tag;
  uint8_t padding_0[4];
  classify_payload payload;
} classify_value;
typedef struct {
  int64_t field_0;
} classify_input;
typedef struct {
  classify_value value;
} classify_output;
extern uint32_t classify_run(const classify_input *, classify_output *);

typedef struct {
  bool field_0;
  uint8_t padding_0[7];
  int64_t field_1;
} product_value;
typedef struct {
  int64_t field_0;
} product_input;
typedef struct {
  product_value value;
} product_output;
extern uint32_t make_product_run(const product_input *, product_output *);

typedef struct {
  product_value field_0;
} projection_input;
typedef struct {
  int64_t value;
} projection_output;
extern uint32_t project_score_run(const projection_input *, projection_output *);

typedef struct {
  double field_0;
} f64_identity_input;
typedef struct {
  double value;
} f64_identity_output;
extern uint32_t f64_identity_run(const f64_identity_input *, f64_identity_output *);

static int run_case(const char *line) {
  int64_t value = 0;
  unsigned flag = 0;
  uint64_t bits = 0;

  if (sscanf(line, "increment %" SCNd64, &value) == 1) {
    increment_input input = {value};
    increment_output output = {0};
    uint32_t status = increment_run(&input, &output);
    if (status == 0) {
      printf("increment:%" PRId64 " status=%" PRIu32 " value=%" PRId64 "\n",
             value, status, output.value);
    } else {
      printf("increment:%" PRId64 " status=%" PRIu32 "\n", value, status);
    }
    return 0;
  }
  if (sscanf(line, "classify %" SCNd64, &value) == 1) {
    classify_input input = {value};
    classify_output output = {0};
    uint32_t status = classify_run(&input, &output);
    int64_t payload = output.value.tag == 0 ? output.value.payload.variant_0
                                            : output.value.payload.variant_1;
    printf("classify:%" PRId64 " status=%" PRIu32 " tag=%" PRIu32
           " value=%" PRId64 "\n",
           value, status, output.value.tag, payload);
    return 0;
  }
  if (sscanf(line, "product %" SCNd64, &value) == 1) {
    product_input input = {value};
    product_output output = {0};
    uint32_t status = make_product_run(&input, &output);
    printf("product:%" PRId64 " status=%" PRIu32 " flag=%u score=%" PRId64 "\n",
           value, status, output.value.field_0 ? 1u : 0u, output.value.field_1);
    return 0;
  }
  if (sscanf(line, "projection %u %" SCNd64, &flag, &value) == 2) {
    projection_input input = {
        .field_0 = {.field_0 = flag != 0, .padding_0 = {0}, .field_1 = value}};
    projection_output output = {0};
    uint32_t status = project_score_run(&input, &output);
    printf("projection:%u,%" PRId64 " status=%" PRIu32 " value=%" PRId64 "\n",
           flag, value, status, output.value);
    return 0;
  }
  if (sscanf(line, "f64 %" SCNx64, &bits) == 1) {
    f64_identity_input input = {0};
    f64_identity_output output = {0};
    uint64_t output_bits = 0;
    memcpy(&input.field_0, &bits, sizeof(bits));
    uint32_t status = f64_identity_run(&input, &output);
    memcpy(&output_bits, &output.value, sizeof(output_bits));
    printf("f64:%016" PRIx64 " status=%" PRIu32 " bits=%016" PRIx64 "\n",
           bits, status, output_bits);
    return 0;
  }
  fprintf(stderr, "invalid NativePure differential case: %s\n", line);
  return 2;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: native-pure-differential-harness CASE\n");
    return 2;
  }
  return run_case(argv[1]);
}
