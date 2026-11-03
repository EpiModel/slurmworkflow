# Local tests: running a step payload in a new shell

This directory holds a small, dependency-free harness for comparing ways to run
the payload `instructions.sh` of a workflow step.

It runs the real templates:

- `inst/templates/workflow/SWF/step.sh`
- `inst/templates/step_dir/job.sh`

with a stub `sbatch` on `PATH`. No Slurm, R, or network access is needed.
The harness itself requires bash 4+ (it uses associative arrays); the runtime
templates remain the usual bash/step scripts.

## Run it

From the repository root:

```bash
bash tests/runtime/test-step-shell.sh
# or, for each case's stdout/stderr/sbatch log:
bash tests/runtime/test-step-shell.sh --verbose
```

The script exits non-zero if an expected behaviour changes.

## Variants

| Variant | Payload invocation |
|---|---|
| `source` | `source "$SWF__INSTRUCTIONS_SCRIPT"` (the old behaviour) |
| `bash` | `env -u BASH_ENV "${BASH:-/bin/bash}" -e -- "$SWF__INSTRUCTIONS_SCRIPT"` |
| `subshell` | `( set -e; source "$SWF__INSTRUCTIONS_SCRIPT" )` |
| `bash-rc` | `set +e; env -u BASH_ENV "${BASH:-/bin/bash}" -e ...; SWF__RC=$?; set -e; exit "$SWF__RC"` |
| `default` | the current `inst/templates/workflow/SWF/step.sh` block, unmodified |

The default template is now `bash-rc`. The harness replaces the block between
the `SWF_PAYLOAD_INVOCATION` markers, so all variants are tested against the
same surrounding step code. The `default` variant verifies the actual template,
not just a patched copy.

`bash` and `bash-rc` run the payload in a separate bash process. `subshell`
runs it in a subshell: a separate process for isolation purposes, but with the
parent shell's non-exported variables and functions still visible and with
top-level `return` still valid.

## Scenarios

Each scenario writes a small `instructions.sh` and then runs `job.sh` as Slurm
would, with `SLURM_JOB_ID=1000` and no array variables.

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

## Current results

`h=1` means the step submitted the controller via the stub `sbatch`.

```text
scenario       source                 bash                   subshell               bash-rc
ok             rc=0 h=1               rc=0 h=1               rc=0 h=1               rc=0 h=1
exit0          rc=0 h=0               rc=0 h=1               rc=0 h=1               rc=0 h=1
exit1          rc=1 h=0               rc=1 h=0               rc=1 h=0               rc=1 h=0
exec           rc=0 h=0               rc=0 h=1               rc=0 h=1               rc=0 h=1
cd             rc=0 h=1 cwd=alt       rc=0 h=1 cwd=project   rc=0 h=1 cwd=project   rc=0 h=1 cwd=project
set_u          rc=1 h=0               rc=0 h=1               rc=0 h=1               rc=0 h=1
path           rc=127 h=0             rc=0 h=1               rc=0 h=1               rc=0 h=1
function       rc=0 h=0 hijacked=yes  rc=0 h=1 hijacked=no   rc=0 h=1 hijacked=no   rc=0 h=1 hijacked=no
return         rc=0 h=1               rc=2 h=0               rc=0 h=1               rc=2 h=0
var            rc=0 h=1 ctrl=/bogus   rc=0 h=1 ctrl=controller rc=0 h=1 ctrl=controller rc=0 h=1 ctrl=controller
nonexport      rc=0 h=1 var=visible   rc=0 h=1 var=hidden    rc=0 h=1 var=visible   rc=0 h=1 var=hidden
nextstep       rc=0 h=1 next=3        rc=0 h=1 next=3        rc=0 h=1 next=3        rc=0 h=1 next=3
```

The `default` variant produces the same matrix as `bash-rc`.

## What the tests show

- `source` lets the payload control the framework shell: `exit 0` and `exec`
  skip the hand-off, `cd` moves the next step, `set -u` and `PATH` changes kill
  the hand-off, a `sbatch` function hijacks it, and framework variables can be
  overwritten.
- `bash` and `bash-rc` isolate all of that. The trade-offs are:
  - top-level `return` is no longer valid;
  - non-exported variables such as `SWF__JOB_ID` are not visible;
  - `sbatch` must be on the parent shell's `PATH`; module loads inside the
    payload do not help the parent submit the controller.
- `subshell` isolates `exit`, `exec`, `cd`, `set -u`, `PATH`, and function
  definitions, while preserving `return` and non-exported variables. It is the
  least disruptive migration, but it exposes more of the framework's shell to
  the payload.
- `bash-rc` behaves like `bash` for these scenarios and additionally records
  the payload exit code. It still exits before the hand-off on failure; it is
  not a replacement for P3/P12 failure handling.

## Not covered

This harness deliberately does not test:

- SIGTERM, time limits, OOM, or `scancel` (the payload can be killed before it
  writes anything);
- private temporary directories for next-step files (`mktemp -d`) or the
  shared-`/tmp` injection path;
- `BASH_ENV` being read by the child `bash`;
- real Slurm dependencies, array task order, or `afterany` semantics;
- the controller and run-identity work (P1/P3/P12).

Those belong in a mock-Slurm harness with a job queue and fault injection, as
described in `slurmworkflow/review/05-reference-implementation.md`.

## Adding a scenario

Add the payload to `write_payload()` and the name to `scenarios`. If the
behaviour needs an assertion, add it in the "Expected invariants" section.
Keep the harness bash-only and self-contained.
