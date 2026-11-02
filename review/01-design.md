# 1. Design and goals of the slurmworkflow runtime

This document describes what the runtime does today, and which assumptions
it relies on without saying so. It is descriptive. The problems are in
[03-findings.md](03-findings.md) and the fixes in
[04-proposals.md](04-proposals.md).

Reviewed code: branch `dev` at `84e5f11`. The `merck_calib2` deployment in
`../swf_logs` was generated from identical templates. Only `controller.sh`
differs, by the brewed `#SBATCH --partition` line.

---

## 1.1 Goals

Stated in the README and vignette:

| # | Goal | How it is met |
|---|------|---------------|
| G1 | Define a multi-step HPC pipeline locally, in R | `create_workflow()` / `add_workflow_step()` write a directory |
| G2 | Ship it as a self-contained directory (`scp` / `git`) | every script, serialized R object and `#SBATCH` header is in `workflows/<name>/` |
| G3 | No persistent SSH session and no daemon | each job submits its successor with `sbatch`, so the chain keeps itself going |
| G4 | Run-time control flow: loops and conditional jumps | a running step writes the number of the next step to a file (`change_next_workflow_step()`) |
| G5 | Huge `Map()`-style arrays despite site array limits | `step_tmpl_map()` submits arrays in slices of `max_array_size` and re-submits itself |
| G6 | Per-step resources | each step has its own `job.sh` with its own `#SBATCH` lines |
| G7 | Few requirements on the cluster | bash, Slurm, and R only for R steps. Tested on Emory RSPH and UW HYAK |

Non-goals that follow from the design: no retries, no resume, no status
view, no notion of concurrent runs (they happen, by accident or on
purpose, but nothing guards against them or tells them apart), and no
parallel branches (a workflow is one linear chain with jumps).

G3 and G4 together rule out the obvious alternative of submitting every
step up front with a static dependency graph, because loops are unbounded
and branches are only known at run time. A chain that rebuilds itself one
hop at a time is the right basic choice for these goals. The review is
about how that chain is put together, not about whether to have one.

---

## 1.2 Files in a workflow directory

```
workflows/<wf>/
├── start_workflow.sh          login node: entry point, submits the first controller
├── workflow.yaml              metadata written by R (not read by the bash runtime)
├── log/                       created on first start
│   ├── <wf>_controller.out    shared by every controller job (append mode)
│   └── <wf>_step<N>_<%A>_<%a>.out
└── SWF/
    ├── lib.sh                 path conventions (make_env_vars, make_env_cur_vars) + CRLF fixer
    ├── controller.sh          tiny sbatch job: submits step N or prints "All steps are done"
    ├── step.sh                common body of every step: runs instructions, then hands off
    └── steps/<N>/
        ├── job.sh             #SBATCH header for step N, then sources lib.sh and step.sh
        ├── instructions.sh    the user's work for step N (bash, possibly `Rscript ...`)
        └── script.R, *.rds    R templates only: runner script + serialized call
```

---

## 1.3 Run-time protocol

### Lifecycle of one run

```
 login node                     compute nodes
 ──────────                     ─────────────
 ./start_workflow.sh [-s N] [-d dir]
   │  realpath SWF_ROOT, mkdir log/, fix CRLF
   │  sbatch --output=log/%x.out --job-name=<wf>_controller controller.sh ROOT N
   ▼
 ┌────────────── controller(N) ── 1 cpu, 500 MB, 10 min, --export=NONE ─────────┐
 │ if steps/N/job.sh exists:                                                     │
 │   sbatch --dependency=afterany:<self> --output=log/%x_%A_%a.out               │
 │          --job-name=<wf>_step<N>  [extra opts]  steps/N/job.sh ROOT N         │
 │ else: echo "All steps are done"            ← the only "end of workflow" signal │
 └───────────────────────────────────────────────────────────────────────────────┘
   ▼  (starts once the controller has ended)
 ┌────────────── step N (job.sh, maybe an array) ── --export=NONE ───────────────┐
 │ set -e; source lib.sh; source step.sh                                         │
 │   source instructions.sh            ← same shell, same cwd, errexit on       │
 │   if not an array, or SLURM_ARRAY_TASK_ID == SLURM_ARRAY_TASK_MAX:           │
 │     next = content of $TMP/<jobid>.nextstep, or N+1                          │
 │     opts = content of $TMP/<jobid>.nextstep_opts, or ""                      │
 │     sbatch --dependency=afterany:<own SLURM_JOB_ID> controller.sh ROOT next opts│
 └───────────────────────────────────────────────────────────────────────────────┘
   ▼
 controller(next) → step next → ...
```

Each hop is two queued jobs: a controller, then a step. The successor is
submitted from inside the job that is about to finish, with an `afterany`
dependency on that job, so jobs of a run never overlap.

### What passes between jobs

| Channel | Producer → consumer | Content |
|---|---|---|
| positional args `$1 $2 [$3]` | every `sbatch` call | `SWF_ROOT` (absolute, from `realpath` on the login node), step number, extra sbatch options as **one string** |
| `lib.sh` | every job | rebuilds all paths from `$1`/`$2` (no inherited environment because of `--export=NONE`) |
| `SWF_NEXTSTEP_FILE` = `$TMP/<SLURM_JOB_ID>.nextstep` | R `change_next_workflow_step()` → `step.sh` tail, **same job, same node** | next step number, checked against `^[1-9][0-9]*$` |
| `SWF_NEXTSTEP_OPTS_FILE` = `…​.nextstep_opts` | same | `--opt=value --opt=value` (space-joined), word-split by the controller |
| `--export=SWF__ARRAY_OFFSET=k` | R map template → map step | 1-based offset of the current array slice |
| working directory | inherited by every `sbatch` from its caller | must stay the project root (relative R paths, renv `.Rprofile`) |

Environment variable conventions (`lib.sh`, `step.sh`): `SWF_*` is public
and read by user code (`SWF_ROOT`, `SWF_CUR`, `SWF_NEXTSTEP_FILE`,
`SWF_CUR_TMP`, …), while `SWF__*` is internal plumbing.

### Control flow API

- `change_next_workflow_step(n, sbatch_opts)` writes the two files. The
  `step.sh` tail reads them, but only in a non-array job or in the
  highest-index array task.
- No file means the next step is `N+1`.
- A run ends when `steps/<next>/job.sh` does not exist. This covers both
  the normal end and any invalid step number.

### Array slicing (`step_tmpl_map`)

`job.sh` asks for `--array=0-(k-1)` with `--export=SWF__ARRAY_OFFSET=1`,
and task `i` handles item `i + offset`. The highest-index task of a slice
calls `change_next_workflow_step(<same step>, list(array=…, export="SWF__ARRAY_OFFSET=…"))`
before running its own item. The step therefore loops on itself until
every item is covered. Each slice starts only after the previous slice
has completely finished.

### Environment policy

`controller.sh` and every `job.sh` use `#SBATCH --export=NONE`. The job
gets a clean environment plus Slurm's implicit login-environment load, so
login-node state (loaded modules and so on) does not leak into jobs. Map
steps also carry `#SBATCH --export=SWF__ARRAY_OFFSET=…`. That later
directive **replaces** `NONE` instead of adding to it. Slurm happens to
treat a variable list like `NONE` plus those variables, so the effective
environment is the same (see F8 in the findings). In every mode, Slurm
also copies the submitting job's `SLURM*` variables into the new job
(F28).

### Working directory

No job sets `--chdir`, and only `start_workflow.sh -d` calls `cd`. Every
job runs in the directory its `sbatch` was called from, which is the
directory `start_workflow.sh` was run from (or `-d`). R generates relative paths
(`Rscript "workflows/<wf>/SWF/steps/N/script.R"`), and renv activates from
the `.Rprofile` in the working directory. The vignette says the workflow
"will not work if you are not at the root of your project". Nothing checks
this.

### Logging

- `log/<wf>_controller.out`: every controller of every run, appended. It
  holds the two lines `Submitted batch job X` and `Step number N has been
  submitted`.
- `log/<wf>_step<N>_<%A>_<%a>.out`: stdout and stderr of a step. R
  templates add a start banner, `gc()`, a warnings summary and the
  duration. Bash steps add nothing.

### Failure semantics as implemented

| Event | Effect |
|---|---|
| instruction fails (`set -e`) | job exits non-zero, no successor submitted, **chain stops** |
| step killed (time limit, OOM, preemption, node failure, `scancel`) | tail never runs, **chain stops** |
| highest-index array task fails or is killed | **chain stops**, even if every other task succeeded |
| any other array task fails | ignored. The successor already waits on `afterany`, so the next step runs |
| `sbatch` fails in the tail or in the controller | job exits non-zero, **chain stops** |
| notification of any of the above | only Slurm's own `--mail-type` on that job, if the user set one |

The dependency type is `afterany`, but the successor only exists if the
step reaches its last line. So the "any" part of `afterany` is never
exercised: a step that fails never submits anything.

---

## 1.4 Unstated assumptions

Every serious finding is a case where one of these does not hold.

| ID | The runtime assumes… | Broken by (examples) | Findings |
|---|---|---|---|
| **A1** | exactly one live chain per workflow directory, unless the user starts another on purpose | an accidental second start; requeue of a job after it submitted its successor | F1 |
| **A2** | each job submits its successor exactly once | requeue (node failure, preemption); `sbatch` that times out but did submit | F1, F13 |
| **A3** | the highest-index array task's `SLURM_JOB_ID` equals the array's job ID, so `afterany` covers the whole array | any task split off the array record out of order | F2 |
| **A4** | user instructions do not `exit`, `cd`, change shell options, or reuse `SWF__*` names | `exit 0`, `cd data`, sourcing a script that runs `set -u`, … | F5, F6, F7 |
| **A5** | the working directory at start is the project root and stays so | starting from elsewhere without `-d`, `cd` in a step, `--chdir` in options | F6, F17 |
| **A6** | `$TMP` (or `/tmp`) is private to the job and the same throughout the job | shared `/tmp` on multi-user nodes | F24 |
| **A7** | compute nodes can call `sbatch`, and the loaded login environment puts it on `PATH` | sites that block submission from nodes; failed login-environment load | F16 |
| **A8** | `partition` + `account` are enough for the controller to be accepted, and a 1-CPU job is cheap and quick to schedule | sites that require `--qos`/`--clusters`/`--constraint`; whole-node allocation; busy queues | F15 |
| **A9** | option values never contain spaces | `--comment`, `--export=A=b c`, … | F12 |
| **A10** | the next-step decision files are written only by the code that means to | map slicing and user code both call `change_next_workflow_step()` in the same task; another user writing to the shared `/tmp` | F4, F24 |
| **A11** | a job's `SLURM_*` variables describe that job | sbatch copies the submitter's `SLURM*` variables into every job it submits, so array and memory variables leak down the chain | F28 |

---

## 1.5 Strengths to keep

- **Small surface.** About 230 lines of bash, easy to audit, with no
  runtime dependency beyond bash and Slurm.
- **Self-contained workflow directories.** Old workflows keep their own
  scripts, so new package versions do not break directories already
  deployed.
- **No daemon, and the chain survives logout.** The only state is in
  Slurm's queue.
- **Dynamic control flow** through a tiny, language-neutral file protocol.
  Any language can write `$SWF_NEXTSTEP_FILE`.
- **Clean environment** via `--export=NONE`, so login-node state does not
  leak into jobs.
- **Careful details:** integer validation of the next step, a guard
  against `source`, CRLF repair for Windows users, append-mode logs, and
  the public/internal split of `SWF_*` vs `SWF__*`.
- **Per-step `#SBATCH` headers** are plain files that can be inspected and
  `sbatch`ed by hand when debugging.

The proposals in [04-proposals.md](04-proposals.md) keep all of these.
