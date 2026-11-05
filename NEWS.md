## slurmworkflow (development version)

- Step payloads now run in a child `bash -e` instead of being sourced into the
  framework shell. `cd`, `set`, `trap`, `PATH`, shell functions, and `exit` no
  longer affect the hand-off. `exit 0` now means success and continues the
  workflow; top-level `return` is no longer valid in a payload. The contract is
  documented in the "Step payload contract" vignette.
- The parent shell forwards `TERM`, `USR1`, and `USR2` to the payload child and
  waits for it to exit before the hand-off.
- `step.sh` checks that `sbatch` is available in the parent shell before running
  the payload.
- `SWF/steps/<N>/job.sh` sources `SWF/parent_setup.sh` if it exists, so sites
  that load the Slurm client through a module can make `sbatch` available to the
  hand-off shell.

## slurmworkflow 0.1.0

First stable release
