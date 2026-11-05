# Local tests: running a step payload in a new shell

This directory holds a small, dependency-free harness for testing the default
payload execution in `inst/templates/workflow/SWF/step.sh` and
`inst/templates/step_dir/job.sh`.

It runs the real templates with a stub `sbatch` on `PATH`. No Slurm, R, or
network access is needed. The harness itself requires bash 4+ (it uses
associative arrays); the runtime templates remain the usual bash/step scripts.

The harness is invoked by `tests/testthat/test-runtime.R` during `R CMD check`
on Unix-like systems.

## Run it

From the repository root:

```bash
bash tests/runtime/test-step-shell.sh
# or, for each case's stdout/stderr/sbatch log:
bash tests/runtime/test-step-shell.sh --verbose
```

The script exits non-zero if an expected behavior changes.

## Scenarios

Each scenario writes a small `instructions.sh` and then runs `job.sh` as Slurm
would, with `SLURM_JOB_ID=1000` and no array variables unless noted.

| Scenario | Payload |
|---|---|
| `ok` | `echo` only |
| `exit0` | `exit 0` |
| `exit1` | `exit 1` |
| `exec` | `exec true` |
| `cd` | `cd "$ALT_DIR"` |
| `set_u` | `set -u` |
| `path` | `PATH=/nonexistent; export PATH` |
| `function` | defines a `sbatch` shell function |
| `return` | top-level `return 0` |
| `var` | overwrites `SWF__CTRL_SCRIPT` |
| `nonexport` | prints `$SWF__JOB_ID` (not exported) |
| `nextstep` | writes `3` to `$SWF_NEXTSTEP_FILE` |
| `array_env` | runs as array task 2/2 and prints `SLURM_ARRAY_*` and `SWF__ARRAY_OFFSET` |
| `bash_env` | checks that a function defined in `BASH_ENV` is visible in the child |
| `sbatch_missing` | runs with `sbatch` absent from `PATH` |
| `signal` | runs a payload with a `TERM` trap and sends `SIGTERM` to the job process group |

## Current results

`h=1` means the step submitted the controller via the stub `sbatch`.

```text
scenario       default
ok             rc=0 h=1
exit0          rc=0 h=1
exit1          rc=1 h=0
exec           rc=0 h=1
cd             rc=0 h=1 cwd=project
set_u          rc=0 h=1
path           rc=0 h=1
function       rc=0 h=1 hijacked=no
return         rc=2 h=0
var            rc=0 h=1 ctrl=controller
nonexport      rc=0 h=1 var=hidden
nextstep       rc=0 h=1 next=3
array_env      rc=0 h=1 env=ok
bash_env       rc=0 h=1 visible=yes
sbatch_missing rc=127 h=0
signal cleanup ran (0.00s)
```

## What the tests show

The child shell isolates the payload from the framework shell:

- `exit 0` continues the workflow; `exit 1` stops before the hand-off.
- `exec true` hands off on success.
- `cd`, `set -u`, `PATH` changes, and shell functions stay in the child.
- Top-level `return` is no longer valid.
- Framework variables such as `SWF__CTRL_SCRIPT` cannot be overwritten for the
  hand-off.
- Non-exported variables such as `SWF__JOB_ID` are not visible.
- Array variables and `SWF__ARRAY_OFFSET` are inherited by the child.
- A function defined in `BASH_ENV` is visible in the child.
- If `sbatch` is not on `PATH`, the step exits 127 before the payload.
- A `TERM` signal sent to the job process group is forwarded to the payload
  child and its cleanup trap runs.

## Not covered

This harness deliberately does not test:

- time limits, OOM, or hard kills that cannot be trapped;
- private temporary directories for next-step files (`mktemp -d`) or the
  shared-`/tmp` injection path;
- real Slurm dependencies, array task order, or `afterany` semantics;
- the controller and run-identity work (P1/P3/P12).

Those belong in a mock-Slurm harness with a job queue and fault injection, as
described in `slurmworkflow/review/05-reference-implementation.md`.

## Adding a scenario

Add the payload to `write_payload()` and the name to `scenarios`. If the
behavior needs an assertion, add it in the "Expected invariants" section.
Keep the harness bash-only and self-contained.
