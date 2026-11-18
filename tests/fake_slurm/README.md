# Fake Slurm

Four executable Bash programs provide a local, stateful Slurm substitute for
runtime tests. They require `FAKE_SLURM_DIR`; put this directory first on
`PATH` before starting a workflow:

```bash
export PATH="$PWD/tests/fake_slurm:$PATH"
export FAKE_SLURM_DIR=/tmp/opencode/my-fake-slurm
mkdir -p "$FAKE_SLURM_DIR"

run_id="$(workflows/example/swf start)"
fake_slurm_run
```

## Commands

- **`sbatch [options] script [args...]`** reserves an id (starting at 1000) and
  records a pending job. It accepts and records arbitrary long options and
  implements arrays, `afterany` dependencies, `--parsable`, `--output`,
  `--job-name`, `--export`, and `--chdir`. Script `#SBATCH` directives are read
  too; command-line options win. Its NUL-delimited `argv` record preserves the
  exact argument boundaries for tests. Invalid array specifications are
  rejected at submission time.
- **`squeue [-h] [-j id,...] [-o format]`** lists pending and running jobs.
  Array members are displayed as `id_task`; `%i`, `%T`, and `%j` are supported
  in the format. `-u` and `--me` are accepted and ignored.
- **`scancel id [...]`** cancels pending or running jobs. `id_task` cancels one
  array member. Unknown and already-finished jobs produce warnings but do not
  make the command fail.
- **`fake_slurm_run [--one] [--max-jobs N]`** runs runnable jobs in ascending
  id order. `--one` runs one submitted job (all of its array tasks), spacing out
  `--max-jobs` submissions, whose default is 500. Jobs blocked by unfinished
  dependencies are skipped. Array tasks run sequentially and receive distinct
  `SLURM_JOB_ID` values. One line is printed for each submitted job run; a live
  runnable backlog after the maximum produces exit status 2.

`afterany` dependencies are satisfied by `COMPLETED`, `FAILED`, or `CANCELLED`
parents. An array is `FAILED` if any task fails, but its remaining tasks still
run. Output is appended after substituting `%x`, `%j`, `%A`, and `%a`.

## State and environment

Each `$FAKE_SLURM_DIR/jobs/<id>/` directory contains state and metadata files.
`state` changes from `PENDING` through `RUNNING` to `COMPLETED`, `FAILED`, or
`CANCELLED`; `argv` and `args` are NUL-delimited. No metadata file is sourced.

`--export=ALL` inherits the runner's environment. With `NONE`, the runner uses
`env -i`, retains `HOME`, `PATH`, `USER`, and `LANG`, and adds variables named
in the space-separated `FAKE_SLURM_KEEP_ENV` (for example `R_LIBS`) and any
values from `--export=NONE,K=V,...`. `FAKE_SLURM_DIR` and
`FAKE_SLURM_KEEP_ENV` are always retained as test-harness infrastructure, so
controller jobs can submit their successors even when the caller only lists
`R_LIBS` in `FAKE_SLURM_KEEP_ENV`.

Run the engine suite in either supported shell compatibility mode:

```bash
bash tests/runtime/test-engine.sh
BASH_COMPAT=4.2 bash tests/runtime/test-engine.sh
```
