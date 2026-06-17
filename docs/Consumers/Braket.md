---
title: Amazon Braket Consumer Setup
description:
  AWS account, IAM, S3, and OpenQASM smoke-test setup for an Amazon Braket quantum host binding.
sidebar:
  label: Amazon Braket
  order: 5
status: draft
---

# Amazon Braket Consumer Setup

This page is a consumer setup guide. It prepares an AWS account for a quantum host that submits
Wire-authored circuits to Amazon Braket as OpenQASM 3. Cortex still owns Wire parsing, typed graph
composition, and executor admission. The Braket host owns AWS credentials, S3 result storage, device
choice, queue policy, shot count, spending limits, and result interpretation.

Braket does not use a separate Braket API key. Local code authenticates with normal AWS IAM
credentials, and the Braket service uses AWS service roles inside the account.

The Cortex development shell includes AWS CLI v2. The repository's Braket runner also receives the
AWS CLI store path from its Nix app, so `nix run .#wire-quantum-braket` works without separately
installing the Amazon Braket Python SDK.

## Environment Names

Use these local environment variables for Cortex-side Braket setup:

```bash
export CORTEX_BRAKET_ACCESS_KEY="<aws-access-key-id>"
export CORTEX_BRAKET_SECRET_KEY="<aws-secret-access-key>"
export CORTEX_BRAKET_BUCKET="amazon-braket-cortex-results-<account-id>-us-east-1"
export CORTEX_BRAKET_PREFIX="cortex/dev"
export CORTEX_BRAKET_REGION="us-east-1"
```

Older notes may call the access-key variable `CORTEX_BRAKET_ACCESS`. Map it before configuring AWS:

```bash
export CORTEX_BRAKET_ACCESS_KEY="${CORTEX_BRAKET_ACCESS_KEY:-${CORTEX_BRAKET_ACCESS:-}}"
```

Do not commit access keys, generated AWS credential files, or local Braket config files.

## Enable Braket

In the AWS Console, open **Amazon Braket** and complete the onboarding wizard. The wizard may
create:

- `AWSServiceRoleForAmazonBraket`
- `AmazonBraketJobsExecutionRole`
- third-party device enablement
- provider spending limits

You do not need to attach these service roles to the IAM user used by Cortex. The IAM user is the
local API identity. `AWSServiceRoleForAmazonBraket` is used internally by AWS for Braket tasks.
`AmazonBraketJobsExecutionRole` is only needed for Braket Hybrid Jobs. A notebook instance is not
required for the CLI or SDK smoke tests.

Check the roles:

```bash
aws iam get-role \
  --role-name AWSServiceRoleForAmazonBraket \
  --profile cortex-braket \
  --region us-east-1

aws iam get-role \
  --role-name AmazonBraketJobsExecutionRole \
  --profile cortex-braket \
  --region us-east-1
```

If the service-linked role is missing and your identity is allowed to create it:

```bash
aws iam create-service-linked-role \
  --aws-service-name braket.amazonaws.com \
  --profile cortex-braket
```

Without `AWSServiceRoleForAmazonBraket`, `create-quantum-task` fails before a task is queued.

## Create IAM Access

Create an IAM user for local API access, for example:

```text
cortex-braket
```

Create or use a group such as:

```text
cortex-braket-users
```

For initial testing, attach the AWS managed policy:

```text
AmazonBraketFullAccess
```

This is intentionally broad for setup validation. Replace it with a least-privilege policy once the
backend is working.

Then create an access key:

```text
IAM -> Users -> cortex-braket -> Security credentials -> Access keys -> Create access key
```

Use case:

```text
Command Line Interface (CLI)
```

AWS will show `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Store them in your local secret
manager and export them as `CORTEX_BRAKET_ACCESS_KEY` and `CORTEX_BRAKET_SECRET_KEY`.

## Create The S3 Result Bucket

Braket writes task results to S3. Create a private S3 bucket in the same region used for Braket.

Recommended starting region:

```text
us-east-1
```

Bucket names should start with:

```text
amazon-braket-
```

Example:

```text
amazon-braket-cortex-results-<account-id>-us-east-1
```

Recommended bucket settings:

```text
Bucket type: General purpose
Object ownership: ACLs disabled / bucket owner enforced
Block all public access: enabled
Versioning: disabled
Encryption: SSE-S3
Object Lock: disabled
```

Use a prefix for development results:

```text
cortex/dev
```

The IAM identity used for local smoke tests needs list, read, write, and usually delete access for
that prefix. If delete is omitted, task submission can still work, but cleanup commands will leave
test objects behind. A prefix-scoped S3 policy has this shape:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBraketResultPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::BUCKET_NAME",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["cortex/dev", "cortex/dev/*"]
        }
      }
    },
    {
      "Sid": "UseBraketResultPrefix",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/cortex/dev/*"
    }
  ]
}
```

Replace `BUCKET_NAME` and `cortex/dev` with the bucket and prefix used by the account.

## Configure The Local AWS Profile

From the Cortex repository, enter the development shell:

```bash
nix develop
aws --version
```

Or, outside the repository, use a temporary Nix shell with AWS CLI v2:

```bash
nix shell nixpkgs#awscli2
```

Create the AWS profile from the Cortex environment variables:

```bash
set -euo pipefail

export CORTEX_BRAKET_ACCESS_KEY="${CORTEX_BRAKET_ACCESS_KEY:-${CORTEX_BRAKET_ACCESS:-}}"
: "${CORTEX_BRAKET_ACCESS_KEY:?set CORTEX_BRAKET_ACCESS_KEY}"
: "${CORTEX_BRAKET_SECRET_KEY:?set CORTEX_BRAKET_SECRET_KEY}"
: "${CORTEX_BRAKET_BUCKET:?set CORTEX_BRAKET_BUCKET}"
export CORTEX_BRAKET_PREFIX="${CORTEX_BRAKET_PREFIX:-cortex/dev}"
export CORTEX_BRAKET_REGION="${CORTEX_BRAKET_REGION:-us-east-1}"

mkdir -p ~/.aws

aws configure set aws_access_key_id "$CORTEX_BRAKET_ACCESS_KEY" \
  --profile cortex-braket

aws configure set aws_secret_access_key "$CORTEX_BRAKET_SECRET_KEY" \
  --profile cortex-braket

aws configure set region "$CORTEX_BRAKET_REGION" \
  --profile cortex-braket

aws configure set output json \
  --profile cortex-braket
```

For SDKs and subprocesses that rely on standard AWS environment variables:

```bash
export AWS_PROFILE="cortex-braket"
export AWS_REGION="${CORTEX_BRAKET_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${CORTEX_BRAKET_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="$CORTEX_BRAKET_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$CORTEX_BRAKET_SECRET_KEY"
```

## Verify Identity And S3

Check the profile:

```bash
aws configure list-profiles

aws sts get-caller-identity \
  --profile cortex-braket
```

The identity response should contain the AWS account ID and the IAM user ARN.

Check bucket listing:

```bash
aws s3 ls "s3://${CORTEX_BRAKET_BUCKET}" \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}"
```

Check write, read, and delete under the configured prefix:

```bash
echo "braket test $(date -Iseconds)" > /tmp/braket-test.txt

aws s3 cp /tmp/braket-test.txt \
  "s3://${CORTEX_BRAKET_BUCKET}/${CORTEX_BRAKET_PREFIX}/braket-test.txt" \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}"

aws s3 cp \
  "s3://${CORTEX_BRAKET_BUCKET}/${CORTEX_BRAKET_PREFIX}/braket-test.txt" \
  - \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}"

aws s3 rm \
  "s3://${CORTEX_BRAKET_BUCKET}/${CORTEX_BRAKET_PREFIX}/braket-test.txt" \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}"
```

If the last command fails with `s3:DeleteObject`, add delete permission for the result prefix or
clean up test objects through another administrative identity.

## Verify Braket Device Access

Some AWS CLI versions require `--filters` for `braket search-devices`, and currently only document
`deviceArn` as a filter name. Use an empty filter list for an unfiltered search:

```bash
aws braket search-devices \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}" \
  --filters '[]' \
  --query 'devices[*].{name:deviceName,status:deviceStatus,type:deviceType,arn:deviceArn}' \
  --output table
```

The managed simulators `SV1`, `TN1`, and `dm1` should appear as `ONLINE` in `us-east-1`. QPUs may be
online, offline, retired, or gated by provider setup and spending limits.

## Run The Wire Braket Runner

After identity, S3, and device checks pass, validate the repository runner without submitting a
task:

```bash
nix run .#wire-quantum-braket -- \
  examples/wire/quantum-bell-state-ibm-rest.wire \
  --dry-run \
  --json
```

Submit the same Wire-authored Bell circuit to the managed simulator `SV1`:

```bash
nix run .#wire-quantum-braket -- \
  examples/wire/quantum-bell-state-ibm-rest.wire \
  --shots 100 \
  --confirm-hardware \
  --json
```

If the bucket or profile is not exported in the shell, pass them explicitly:

```bash
nix run .#wire-quantum-braket -- \
  examples/wire/quantum-bell-state-ibm-rest.wire \
  --shots 100 \
  --s3-bucket "$CORTEX_BRAKET_BUCKET" \
  --s3-prefix "${CORTEX_BRAKET_PREFIX:-cortex/dev}" \
  --profile cortex-braket \
  --confirm-hardware \
  --json
```

The runner defaults to:

```text
device: arn:aws:braket:::device/quantum-simulator/amazon/sv1
region: us-east-1
profile: cortex-braket
shots: 100
```

Use `--backend sv1`, `--backend tn1`, `--backend dm1`, or `--device-arn <arn>` to select another
Braket device. Start with `SV1`; third-party QPUs should be gated by provider setup and spending
limits.

The runner lowers the admitted Wire quantum plan into Braket OpenQASM 3. Current lowering details:

- Wire `@quantum.sx` is emitted as Braket `v`.
- Wire `@quantum.rzz` is decomposed into `cnot/rz/cnot`.
- Unmeasured qubits are measured into extra classical bits when needed so managed simulator results
  contain a full measurement row.
- Result JSON is normalized into the same `counts`, `labeled_counts`, and `output_counts` shape used
  by the existing Qiskit and IBM REST runners.
- Result JSON includes a `cost_estimate` object and top-level `estimated_cost_usd` when the runner
  has enough pricing data. QPU estimates use public Braket per-task and per-shot pricing. SV1
  estimates use public per-minute simulator pricing and task start/end metadata. These are
  estimates, not AWS billing records.

The estimate excludes S3, taxes, discounts, credits, reservations, free-tier credits, and later AWS
billing adjustments. For devices not in the embedded pricing table, override pricing explicitly:

```bash
export CORTEX_BRAKET_TASK_PRICE_USD="0.30"
export CORTEX_BRAKET_SHOT_PRICE_USD="0.00160"
```

For managed simulator experiments with a custom rate:

```bash
export CORTEX_BRAKET_SIMULATOR_MINUTE_PRICE_USD="0.075"
```

The IBM-era Wire experiments can now run through Braket by swapping the app:

```bash
nix run .#wire-quantum-qec-repetition-braket -- --confirm-hardware
```

```bash
nix run .#wire-quantum-eraser-braket -- --confirm-hardware
```

```bash
nix run .#wire-quantum-ipea-braket -- --bits 3 --shots 100 --confirm-hardware
```

For the larger QEC and eraser sweeps, inspect individual selected circuits first:

```bash
nix run .#wire-quantum-braket -- \
  examples/wire/qec-repetition-code-forced-errors.wire \
  --return qec_repetition_x1 \
  --dry-run \
  --json
```

```bash
nix run .#wire-quantum-braket -- \
  examples/wire/quantum-eraser-experiment.wire \
  --return eraser_phase_0 \
  --dry-run \
  --json
```

The QEC wrapper submits four Braket tasks. The eraser wrapper submits nine Braket tasks. The IPEA
wrapper submits one Braket task per measured phase bit.

## Submit A CLI OpenQASM Smoke Test

This test submits a two-qubit Bell-state circuit to the managed simulator `SV1`. It validates the
same OpenQASM and S3 result path a Braket host binding needs, without requiring the Braket Python
SDK.

Create the OpenQASM source and Braket action payload:

```bash
cat > /tmp/braket-bell.qasm <<'QASM'
OPENQASM 3.0;
qubit[2] q;
bit[2] c;

h q[0];
cnot q[0], q[1];

c[0] = measure q[0];
c[1] = measure q[1];
QASM

ACTION="$(jq -Rs \
  '{braketSchemaHeader:{name:"braket.ir.openqasm.program",version:"1"},source:.}' \
  /tmp/braket-bell.qasm)"
```

Submit the task:

```bash
RUN_PREFIX="${CORTEX_BRAKET_PREFIX%/}/cli-openqasm-$(date -u +%Y%m%dT%H%M%SZ)"

TASK_ARN="$(aws braket create-quantum-task \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}" \
  --device-arn arn:aws:braket:::device/quantum-simulator/amazon/sv1 \
  --shots 100 \
  --output-s3-bucket "$CORTEX_BRAKET_BUCKET" \
  --output-s3-key-prefix "$RUN_PREFIX" \
  --action "$ACTION" \
  --query quantumTaskArn \
  --output text)"

echo "$TASK_ARN"
```

Poll until the task settles. Do not name the shell variable `status` in zsh; it is read-only there.

```bash
while true; do
  task_state="$(aws braket get-quantum-task \
    --quantum-task-arn "$TASK_ARN" \
    --profile cortex-braket \
    --region "${CORTEX_BRAKET_REGION:-us-east-1}" \
    --query status \
    --output text)"

  echo "status=${task_state}"

  case "$task_state" in
    COMPLETED|FAILED|CANCELLED)
      break
      ;;
  esac

  sleep 5
done
```

Fetch the metadata and result URI:

```bash
TASK_JSON="$(aws braket get-quantum-task \
  --quantum-task-arn "$TASK_ARN" \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}" \
  --output json)"

echo "$TASK_JSON" | jq '{
  status: .status,
  quantumTaskArn: .quantumTaskArn,
  deviceArn: .deviceArn,
  shots: .shots,
  outputS3Bucket: .outputS3Bucket,
  outputS3Directory: .outputS3Directory,
  failureReason: .failureReason
}'

RESULT_URI="$(echo "$TASK_JSON" | jq -r \
  '"s3://\(.outputS3Bucket)/\(.outputS3Directory)/results.json"')"

echo "$RESULT_URI"
```

Read and count the measurements:

```bash
aws s3 cp "$RESULT_URI" - \
  --profile cortex-braket \
  --region "${CORTEX_BRAKET_REGION:-us-east-1}" |
  jq '{
    shots: .taskMetadata.shots,
    counts: (
      .measurements
      | map(join(""))
      | group_by(.)
      | map({key: .[0], value: length})
      | from_entries
    )
  }'
```

Expected result: 100 shots split mostly between `00` and `11`, for example:

```json
{
  "shots": 100,
  "counts": {
    "00": 56,
    "11": 44
  }
}
```

For CLI-submitted OpenQASM tasks, the raw result JSON may contain `measurements` but no populated
`measurementCounts` field. Counting `measurements` directly is portable for this smoke test.

## Optional Python SDK Smoke Test

Use the Python SDK when the project environment includes it. The Cortex dev shell does not currently
ship `amazon-braket-sdk`, so use a separate virtual environment if needed:

```bash
python -m venv /tmp/braket-sdk
source /tmp/braket-sdk/bin/activate
pip install amazon-braket-sdk
```

Create `/tmp/test-qasm-braket.py`:

```python
import os

from braket.aws import AwsDevice
from braket.ir.openqasm import Program

bucket = os.environ["CORTEX_BRAKET_BUCKET"]
prefix = os.environ.get("CORTEX_BRAKET_PREFIX", "cortex/dev")

qasm = """
OPENQASM 3.0;
qubit[2] q;
bit[2] c;

h q[0];
cnot q[0], q[1];

c[0] = measure q[0];
c[1] = measure q[1];
"""

device = AwsDevice("arn:aws:braket:::device/quantum-simulator/amazon/sv1")

task = device.run(
    Program(source=qasm),
    s3_folder=(bucket, prefix),
    shots=100,
)

print("Task ARN:", task.id)
result = task.result()
print(result.measurement_counts)
```

Run it:

```bash
AWS_PROFILE=cortex-braket \
AWS_DEFAULT_REGION="${CORTEX_BRAKET_REGION:-us-east-1}" \
python /tmp/test-qasm-braket.py
```

Expected result: counts mostly split between `00` and `11`.

## Troubleshooting

`The config profile (cortex-braket) could not be found`

: Run the profile setup commands again from a shell where the `CORTEX_BRAKET_*` variables are
exported.

`search-devices` requires `--filters`

: Use `--filters '[]'`. Some AWS CLI versions reject `deviceType` filters even though they can
return `deviceType` in the output.

`AWSServiceRoleForAmazonBraket role doesn't exist`

: Complete the Braket onboarding wizard or create the service-linked role with
`aws iam create-service-linked-role --aws-service-name braket.amazonaws.com`.

`AccessDenied` on `s3:DeleteObject`

: The account can write and read results but cannot clean up test objects. Add `s3:DeleteObject` for
the result prefix if automatic cleanup matters.

No `measurementCounts` in `results.json`

: Count `.measurements` directly, as shown in the CLI smoke test. SDK helpers may compute
measurement counts client-side.

## Cost Notes

Braket can incur costs for:

- QPU shots
- managed simulators
- notebooks
- hybrid jobs
- S3 storage

For development, start with `SV1`, low shot counts, and a development-only S3 prefix. Configure
provider spending limits before using third-party QPUs.

## Related

- [Quantum Consumer Binding Example](Quantum.md)
- [QEC Repetition-Code Consumer Example](QEC.md)
- [../Reference/Wire/executors-and-alphabet.md](../Reference/Wire/executors-and-alphabet.md)
- [../Reference/Wire/configured-executors-and-execution-boundary.md](../Reference/Wire/configured-executors-and-execution-boundary.md)
