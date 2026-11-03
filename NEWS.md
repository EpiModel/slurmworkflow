## slurmworkflow (development)

- Step payloads now run in a child `bash -e` instead of being sourced into the
  framework shell. `cd`, `set`, `trap`, `PATH`, shell functions, and `exit` no
  longer affect the hand-off. `exit 0` now means success and continues the
  workflow; top-level `return` is no longer valid in a payload. The contract is
  documented in the "Step payload contract" vignette.
- `step.sh` checks that `sbatch` is available in the parent shell before running
  the payload.

## slurmworkflow 0.1.0

First stable release
