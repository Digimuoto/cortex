---
title: QEC Repetition-Code Consumer Example
description:
  A small Wire-authored quantum error-correction workbench over the quantum consumer binding.
sidebar:
  label: QEC repetition code
  order: 4
status: draft
---

# QEC Repetition-Code Consumer Example

This page is a consumer binding example. It shows how Wire can host a small quantum
error-correction-shaped workflow without making Cortex a QEC platform.

The workbench source is
[`../../examples/wire/qec-repetition-code-forced-errors.wire`](../../examples/wire/qec-repetition-code-forced-errors.wire).
It is a single Wire file with two roles:

- a catalog of four exported circuit graph values;
- a default experiment graph that runs those circuits and renders the report in pure Wire.

## Boundary

The ownership split follows the quantum consumer binding:

| Cortex / Wire owns                                                    | Quantum or QEC host owns                                              |
| --------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Wire parsing, graph composition, typed ports, selected graph returns. | Gate semantics, simulator/hardware binding, provider credentials.     |
| `std.io.command` orchestration and pure `fromJson` report rendering.  | Backend result production and any future real-time decoding policy.   |
| The checked-in experiment topology and expected forced-error table.   | General QEC research semantics beyond this repetition-code workbench. |

The hardware execution path uses the selected quantum runner. There is no QEC-specific Python
analyzer: the runner produces JSON counts, and Wire computes the syndrome-table report with pure
expressions.

## Circuit Shape

The circuit is the distance-3 bit-flip repetition-code memory check for logical zero:

```text
|0_L> = |000>
S01 = Z0 Z1
S12 = Z1 Z2
```

The file exports four graph values:

- `qec_repetition_none`
- `qec_repetition_x0`
- `qec_repetition_x1`
- `qec_repetition_x2`

Each selected graph prepares three data qubits and two fresh syndrome ancillas, injects at most one
forced `X` error, measures the two parity checks, and measures the final data bits. The pure Wire
analyzer expects this lookup table:

| case | raw data | syndrome | correction |
| ---- | -------- | -------- | ---------- |
| none | `000`    | `00`     | none       |
| x0   | `100`    | `10`     | `X d0`     |
| x1   | `010`    | `11`     | `X d1`     |
| x2   | `001`    | `01`     | `X d2`     |

## Hardware Run

Run the full Wire experiment on IBM Quantum Runtime hardware:

```sh
nix run .#wire-quantum-qec-repetition -- --confirm-hardware
```

Run the same Wire experiment on Amazon Braket:

```sh
nix run .#wire-quantum-qec-repetition-braket -- --confirm-hardware
```

The provider app places a `wire-quantum-runner` command on `PATH` and then runs:

```sh
wire run examples/wire/qec-repetition-code-forced-errors.wire
```

The Wire graph creates four `std.io.command` leaves, one per exported circuit graph. Each command
selects its circuit with `wire build --return`, submits it through the selected runner with
`--json`, and returns a `CommandResult`. The final Wire nodes parse those JSON payloads with
`fromJson`, check the forced-error table, print the report, and write
`./wire-qec-repetition-report.txt`.

When every selected runner result includes `estimated_cost_usd`, the pure Wire report also sums the
four task estimates and prints a `Cost estimate` section. The Braket runner provides this field for
known QPU pricing and SV1 simulator runs. The value is an estimate, not an AWS billing record, and
excludes S3, taxes, discounts, credits, reservations, and billing adjustments.

Each selected circuit carries:

```wire
@quantum.ibm_runtime_config { path = "quantum-ibm-runtime.local.json"; }
```

so real credentials should live in the ignored file `examples/wire/quantum-ibm-runtime.local.json`.
For accounts that cannot list provider backends, set a concrete backend in that local config instead
of `least_busy`:

```json
{
  "api_key_env": "QISKIT_IBM_API_KEY",
  "instance_crn": "crn:v1:...",
  "backend": "ibm_backend_name"
}
```

If the Runtime service CRN is regional, keep `api_base_url` in the same region as the CRN. For
example, `eu-de` service instances should use `https://eu-de.quantum.cloud.ibm.com/api/v1`.

The Braket runner ignores the IBM config node as orchestration data and instead reads AWS settings
from `CORTEX_BRAKET_BUCKET`, `CORTEX_BRAKET_PREFIX`, `CORTEX_BRAKET_REGION`, and `AWS_PROFILE`, or
from equivalent command-line flags.

## Local Inspection

To inspect one circuit through the local simulator instead of hardware:

```sh
nix run .#wire-quantum-qiskit -- \
  examples/wire/qec-repetition-code-forced-errors.wire \
  --return qec_repetition_x1 \
  --shots 128 \
  --seed 7 \
  --json
```

## OpenQASM Dry-Run

The same exported graphs can be lowered through the IBM Runtime REST or Braket dry-run paths. The
dry-run builds the OpenQASM 3 request locally and does not submit a hardware job:

```sh
nix run .#wire-quantum-ibm-rest -- \
  examples/wire/qec-repetition-code-forced-errors.wire \
  --return qec_repetition_x1 \
  --dry-run \
  --config examples/wire/quantum-ibm-runtime.config.example.json
```

For Braket:

```sh
nix run .#wire-quantum-braket -- \
  examples/wire/qec-repetition-code-forced-errors.wire \
  --return qec_repetition_x1 \
  --dry-run \
  --json
```

Hardware submission remains explicitly gated by each provider runner's credentials and
`--confirm-hardware` policy. This example remains a forced-error workbench until reset, layout,
timing, and real-time/feedforward semantics are designed.

## Limitations

This is a forced-error repetition-code workbench, not a full QEC stack:

- decoding is offline report logic, not active mid-circuit feedforward;
- ancillas are fresh, not reset and reused;
- no stochastic noise model or repeated syndrome rounds are included yet;
- the report checks a deterministic forced-error table rather than estimating thresholds;
- hardware execution submits four independent sampler jobs, not a live QEC control loop.

## Related

- [Quantum Consumer Binding Example](Quantum.md)
- [../Reference/Wire/executors-and-alphabet.md](../Reference/Wire/executors-and-alphabet.md)
- [../Reference/Wire/configured-executors-and-execution-boundary.md](../Reference/Wire/configured-executors-and-execution-boundary.md)
