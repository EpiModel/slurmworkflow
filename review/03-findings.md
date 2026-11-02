# 3. Findings: shortcomings and risks

Each finding has a severity, a location, a concrete failure scenario, its
evidence, and a pointer to the fix in [04-proposals.md](04-proposals.md).
"Reproduced" means the behaviour was run against the real template files
with a stub `sbatch` (commands in [Appendix A](#appendix-a-reproductions)),
or end to end in the mock-Slurm harness described in 05. "Logs" means it
is visible in `../swf_logs/merck_calib2`. "Slurm source" means it was
checked against SchedMD's code ([Appendix B](#appendix-b-slurm-behaviour-this-review-relies-on)).

Severity scale:
- **Critical**: silent wrong results or large waste in ordinary use; has happened.
- **High**: the workflow stops silently or produces wrong results under plausible conditions.
- **Medium**: a footgun with a visible but confusing failure, a portability limit, or an operability gap.
- **Low**: hygiene.

| ID | Sev. | Title | Evidence |
|---|---|---|---|
| [F1](#f1) | High | Concurrent runs of one workflow can't be told apart, and nothing stops an accidental one | logs, reproduced |
| [F2](#f2) | High | Array hand-off depends on the last task's own job ID | reproduced, Slurm source |
| [F3](#f3) | High | Array failure handling depends on which task fails | code |
| [F4](#f4) | High | Next-step decisions: stale options, silent overwrite, ignored decisions | reproduced (R + bash) |
| [F5](#f5) | High | `exit` in a step's instructions silently ends the workflow | reproduced |
| [F6](#f6) | High | `cd` in a step moves every later step | reproduced |
| [F7](#f7) | Medium | Instructions share the framework's shell: `set -u`, variables, traps | reproduced |
| [F8](#f8) | Medium | Environment handling: overwritten `--export`/`--array`, `srun`, `SBATCH_*`, login-environment failures | code, Slurm source |
| [F9](#f9) | High | Failures are silent; no record, no notification, no status | logs, code |
| [F10](#f10) | Medium | "Finished" and "invalid step number" are the same thing | reproduced |
| [F11](#f11) | Medium | Restart is coarse (`-s N` only) | code |
| [F12](#f12) | Medium | Next-step options are word-split | reproduced |
| [F13](#f13) | Medium | One failed `sbatch` kills the workflow; submissions not idempotent | code, Slurm source |
| [F14](#f14) | Medium | `start_workflow.sh` argument handling | reproduced |
| [F15](#f15) | Medium | Controller resources are hard-coded | logs, code |
| [F16](#f16) | Low | Hidden site requirements | code |
| [F17](#f17) | Medium | Working-directory contract is implicit; relative paths are baked in | code |
| [F18](#f18) | Medium | Map slicing runs as a barrier between slices | code |
| [F19](#f19) | Medium | Logs can't answer "what happened" | logs |
| [F20](#f20) | Low | No guard against runaway loops | code |
| [F21](#f21) | Low | CRLF fixer scans and rewrites too much | code |
| [F22](#f22) | Medium | R steps run *local* package code against the *HPC* namespace | `.rds` inspection |
| [F23](#f23) | Low | Runtime R templates: hidden deps, edge cases, noise | code |
| [F24](#f24) | **High** (security) | Next-step files in shared `/tmp`: another user can inject sbatch options, which leads to code execution | reproduced |
| [F25](#f25) | Low | Unquoted paths | code |
| [F26](#f26) | Low | R accepts sbatch options the runtime breaks on or silently overrides | code |
| [F27](#f27) | Low | Round numbers are written in scientific notation (`--mem=1e+05`) | reproduced |
| [F28](#f28) | Medium | Each job's `SLURM_*` variables leak into the jobs it submits, all the way down the chain | Slurm source |

Two reviews were done independently: this one, and a second agent that
saw only the code and the logs. Both found F1 (the duplicate chain), F2,
F3, F4, F5–F7 and F12–F14 on their own. The second review also
contributed the injection path of F24, F27, the strict-mode-in-arrays
and `PATH` cases of F7, the restart and "can't stop" scenarios of F1 and
F9, and the `SBATCH_EXPORT` case of F8. F28 came from the Slurm source
check.

---

## A. Run identity and concurrency

<a id="f1"></a>
### F1: Concurrent runs of one workflow can't be told apart, and nothing stops an accidental one (High)

**Where:** `start_workflow.sh:58-79`, `step.sh:22-61`, `controller.sh:26-40`.
None of them has any notion of a run.

**What happens.** Every run of `start_workflow.sh` starts a new,
independent chain. Every job submits its successor from inside itself, so
a job that runs twice (because it was requeued after a node failure or
preemption, or because a timed-out `sbatch` went through) also forks the
chain. Chains never notice each other. They have no identity, write to
the same log files, and share the workflow directory and, most
importantly, the project's data files.

**Evidence.** In `merck_calib2`, two complete chains ran in parallel for
9 hours. The second start was deliberate (confirmed by the author), but
the logs alone could not tell it from a requeue. Both chains read and
wrote swfcalib's calibration state, ended in different states (iteration
1 vs 0, with `min/max` warnings in one), and cost about 1,550 extra
core-hours. See
[02-log-analysis.md §2.2](02-log-analysis.md#22-finding-l1-the-whole-workflow-ran-twice-at-the-same-time-on-the-same-state).
Running the start script twice with the stub queues two controllers
without a warning. In the mock Slurm, a requeue after the hand-off forks
the chain (s9 and x4 in 05).

**Severity.** High rather than Critical. The only fork seen so far was
started on purpose, so no accidental fork has been observed. The first
version of this review rated F1 Critical because it assumed the double
start was accidental.

**Why it matters.** Double-starting is an easy human mistake: re-running
a command from shell history, an SSH drop and reconnect, or "did it
start? let me run it again". Requeue-after-submit is rare but cannot be
avoided. The damage is silent and lands in scientific results.

There are other ways to get the same fork:
- **Restarting after a partial array failure.** Task 7 of an array fails,
  so the user restarts with `-s N`. But the highest-index task had already
  queued its controller (`afterany`), which still fires when the array
  ends. The old chain continues next to the new one.
- **A requeue of the highest-index task, or of a controller, after its
  `sbatch` call.** The same job ID reruns from the top and submits a
  second successor.

**Deliberate concurrent runs** are a legitimate use, and `merck_calib2`
is one. Today they look exactly like an accident: no run identity, one
shared controller log, and no way to stop one run without finding its job
IDs by hand. Whether two runs may share a project's state is up to the
step code, and swfcalib has no locking. The runtime should at least make
the second run explicit and keep the runs apart in its own records.

**Fix:** a run ID with fencing, a refusal to start while jobs are queued
unless asked (`-f` replaces the old run, `-p` starts one next to it), and
idempotent hand-offs ([P1](04-proposals.md#p1)).

---

## B. Array steps

<a id="f2"></a>
### F2: Array hand-off depends on the last task's own job ID (High, latent)

**Where:** `step.sh:4` `SWF__JOB_ID=${SLURM_JOB_ID:-$SLURM_ARRAY_JOB_ID}`, used in `step.sh:54`.

**What happens.** `SLURM_JOB_ID` is always set in a batch job, so the
fallback to `SLURM_ARRAY_JOB_ID` never applies. The highest-index task
therefore submits the next controller with
`--dependency=afterany:<its own job id>`. Slurm reads a plain job ID that
equals the array's job ID as "the whole array", and any other task's ID as
"that task only" (verified in `slurmctld/job_scheduler.c`, Appendix B #5).
So the hand-off waits for the whole array only when the highest-index task
happens to own the array's job ID.

When a task starts, Slurm splits it off the pending array record under a
new job ID. The record keeps the original ID and becomes the last task to
start (`job_array_split()`, Appendix B #4). Tasks start lowest index
first, so the highest index usually ends up with the array ID, but nothing
guarantees it. SchedMD's documentation says so: the rule "may not" hold
"if the tasks are not created sequentially due to the tasks being
updated/modified before they start". Known ways to break it:

- an `scontrol update`, `hold` or `release` on individual pending tasks,
  which splits them out early under new IDs;
- cancelling the highest pending index (`scancel 123_31`), which moves
  the array ID to the highest *remaining* index. No task then has
  `TASK_ID == TASK_MAX`, so nothing hands off at all (see F3);
- any future change in the scheduler's split order. Version 23.02's
  documentation example showed the opposite assignment.

When it breaks, the controller and the next step start while other tasks
are still running, and the next step consumes partial results. For
swfcalib, step 3 would score an incomplete batch and move on. The mock
shows the worst case: with task MAX started first, the rest of the
workflow completed before two of the array's tasks had run.

**Evidence.** Reproduced: with `SLURM_JOB_ID=5031 SLURM_ARRAY_JOB_ID=5000
SLURM_ARRAY_TASK_ID=31` the tail submits
`--dependency=afterany:5031`. The logs show the dependency did cover the
whole array in this run
([02 §2.3](02-log-analysis.md#23-finding-l2-array-steps-did-wait-for-every-task-because-task-31-kept-the-arrays-job-id)),
which means task 31 held the array ID each time.

The same variable is also used for the next-step file names (`step.sh:10-11`),
where the per-task ID is what is needed. The two uses have different
requirements and need different variables.

**Fix:** depend on `${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}` and keep
`SLURM_JOB_ID` for file names ([P2](04-proposals.md#p2)).

<a id="f3"></a>
### F3: Array failure handling depends on which task fails (High)

**Where:** `step.sh:22`. Only the task with
`SLURM_ARRAY_TASK_ID == SLURM_ARRAY_TASK_MAX` hands off.

| What fails | What the workflow does |
|---|---|
| the highest-index task (error, time limit, OOM, node failure) | stops silently, even if the other 31 tasks succeeded |
| the highest-index task is cancelled while still pending | stops silently: `SLURM_ARRAY_TASK_MAX` is fixed at submission, so no remaining task matches it |
| any other task | carries on: the hand-off already exists and `afterany` ignores exit codes. The next step runs on partial results |

Time limits and OOM are the most common failures of simulation arrays, so
the first and last rows happen in practice. The first wastes the whole
array. The last is silent data loss: for example, a merge step that
merges 31 of 32 batches without a word.

**Fix:** every task records its exit status, and the next controller
checks all of them before continuing ([P3](04-proposals.md#p3)).

<a id="f4"></a>
### F4: Next-step decisions: stale options, silent overwrite, ignored decisions (High, latent)

**Where:** `R/workflow.R:163-202` (`change_next_workflow_step`), `step.sh:27-51`,
`inst/templates/step_tmpl_map.R:20-38`.

Three defects in the same small protocol:

1. **Stale options.** `change_next_workflow_step(n)` called without
   `sbatch_opts` deletes and rewrites the next-step file but leaves an
   existing options file in place. The tail reads both. Scenario: the map
   template, in the last task of a non-final slice, schedules the next
   slice (`next = this step`, `--array=0-31 --export=SWF__ARRAY_OFFSET=33`).
   The user's function then calls `change_next_workflow_step(3)`. Step 3
   is submitted **as a 32-task array with the slice's offset**. For a
   swfcalib-like step 3, that means 32 concurrent copies rewriting the
   same calibration state.
   *Reproduced* with the package's R code: the files end up as
   `nextstep = 3`, `nextstep_opts = --array=0-31 --export=SWF__ARRAY_OFFSET=33`.
2. **Silent overwrite.** In the same scenario the remaining slices are
   dropped. The only signal is an R `warning()` in a task log ("The
   nextstep file already exists"). Map slicing and user flow control use
   the same single slot.
3. **Ignored decisions.** A call from any array task other than the
   highest index is silently ignored, and its files are left in `/tmp`.
   *Reproduced* (`5007.nextstep` left behind, no hand-off). swfcalib
   avoids this by only deciding when `batch_num == n_batches`. That is
   correct only because the last batch happens to land on the
   highest-index task of the last slice.

Smaller defects in `change_next_workflow_step()` (`R/workflow.R:163-211`):
- `next_step = 3.9` is truncated to 3.
- `0` and negative values are accepted. The bash regex then fails the job
  *after* its work is done.
- The previous decision is deleted before the new value is validated.
- `sbatch_opts` are neither validated nor quoted.
- `get_current_workflow_step()` returns `NA` outside a workflow instead
  of an error.

**Fix:** always replace both files together, refuse conflicting
decisions, and move slicing out of the user's slot
([P4](04-proposals.md#p4)).

---

## C. User instructions run inside the framework's shell

`step.sh:16` *sources* `instructions.sh` into the shell that then runs
the hand-off (`step.sh:22-61`). Anything the instructions do to that shell
changes what the hand-off does. This is the root of F5, F6 and F7, and
one change fixes all three ([P5](04-proposals.md#p5)).

<a id="f5"></a>
### F5: `exit` in a step's instructions silently ends the workflow (High)

`exit 0` ("nothing to do") anywhere in a step, including a user script
copied by `step_tmpl_bash_script()` that ends with `exit 0` or `exit $?`,
leaves the job with status 0 and never reaches the hand-off. The workflow
stops. No error, no `FAIL` mail: success status and a dead chain.
*Reproduced:* job exit 0, zero `sbatch` calls.

<a id="f6"></a>
### F6: `cd` in a step moves every later step (High)

The tail's `sbatch` runs in whatever directory the instructions left it
in. The controller inherits that directory, and so does every later step.
*Reproduced:* instructions `cd /tmp` → controller submitted with
`cwd=/tmp`. R steps use paths relative to the project root
(`Rscript "workflows/<wf>/SWF/steps/N/script.R"`) and renv activates from
the `.Rprofile` in the working directory. So the next R step fails with
"file not found", or worse, runs without the project library. The error
appears one step after its cause. A per-step `--chdir` in `sbatch_opts`
does the same thing.

<a id="f7"></a>
### F7: Instructions share the framework's shell: `set -u`, variables, traps (Medium)

- `set -u` (or `set -euo pipefail`, the usual header of scripts passed
  to `step_tmpl_bash_script()`), or an environment script that enables
  it, makes the tail die. In a non-array job it dies on
  `$SLURM_ARRAY_TASK_ID` (`step.sh:22`). In the last task of an array it
  dies on `$SWF__NEXTSTEP_OPTS` (`step.sh:54`), which is only set when a
  decision was made. In both cases the work is done, the job is marked
  FAILED, and the chain stops. *Reproduced:*
  `step.sh: line 22: SLURM_ARRAY_TASK_ID: unbound variable` and
  `step.sh: line 54: SWF__NEXTSTEP_OPTS: unbound variable`.
- `PATH` changes leak too. `module purge` or `spack unload -a` on a site
  where Slurm itself is a module removes `sbatch`, and the hand-off fails
  with `sbatch: command not found` (exit 127).
- Variables the tail uses can be overwritten (`SWF__CTRL_SCRIPT`,
  `SWF__NEXTSTEP_OPTS`, `SWF_ROOT`, …). *Reproduced:* setting
  `SWF__CTRL_SCRIPT=/bin/oops` makes the tail submit `/bin/oops`.
- `set +e`, `trap … EXIT` and `shopt` changes leak in the same way.

---

## D. Environment and portability

<a id="f8"></a>
### F8: Environment handling: overwritten `--export`/`--array`, `srun`, `SBATCH_*`, login-environment failures (Medium)

**Where:** `job.sh:4`, `R/step_templates.R:175-178`,
`step_tmpl_map.R:28-31`, `controller.sh:9`.

1. Map steps contain `#SBATCH --export=NONE` *and* a later
   `#SBATCH --export=SWF__ARRAY_OFFSET=1`. Later slices pass
   `--export=SWF__ARRAY_OFFSET=k` on the command line. The last one wins,
   so map steps do **not** run with `--export=NONE`. In practice this is
   harmless: a variable list goes through the same code path as `NONE`
   (`SLURM*` + listed variables, plus the implicit login-environment
   load). The effective environment is the same as `NONE` plus the
   offset (Appendix B #2). The fragile part is that this rests on a Slurm
   detail the runtime never states or tests, and points 2 and 4 below
   break it.
   Both `NONE` and a list depend on Slurm loading the login environment
   on the node. When that fails, Slurm ≥ 25.05 requeues and **holds** the
   job, so the workflow stalls. Slurm ≤ 24.11 runs the job with a bare
   environment, where `PATH` may lack `sbatch` and the hand-off fails
   (Appendix B #1).
2. The map template **overwrites** any user-supplied `export` or `array`
   option (`update_sbatch_opts` with the template's list). A user who
   asks for an array throttle (`--array=…%50`) or needs to export a
   variable gets neither, without a message.
3. `--export=NONE` is propagated to job steps through `SLURM_EXPORT_ENV`.
   sbatch sets it in the job's environment **without overwriting an
   existing value**, so the first value in the chain is passed down from
   job to job (F28). An `srun` inside a step (MPI, `srun --cpu-bind`, …)
   then starts tasks without the step's environment (`PATH` from
   `module`/`spack load`). SchedMD's documentation tells users to set
   `SLURM_EXPORT_ENV=ALL` in the script. slurmworkflow doesn't, and
   doesn't document it.
4. `SBATCH_*` input environment variables override `#SBATCH` directives
   (precedence: command line > environment > script). An `SBATCH_PARTITION`
   or `SBATCH_TIMELIMIT` in a user's or site's login profile, loaded into
   every job by `--export=NONE`, silently overrides the options the user
   set in R for every step and every controller. The worst case is
   `SBATCH_EXPORT=ALL`. It replaces the map step's
   `#SBATCH --export=SWF__ARRAY_OFFSET=1`, so the first slice has no
   offset. `as.numeric("")` is `NA`, the highest-index task then errors,
   vector inputs fail with "subscript out of bounds", and **list inputs
   silently become `NULL`** (`list(1, 2)[[NA]]` is `NULL`), so the mapped
   function runs on `NULL` arguments. *Reproduced in R.*

**Fix:** carry the slice offset as a job argument and keep
`--export=NONE` everywhere; `export SLURM_EXPORT_ENV=ALL` in `job.sh`;
warn about `SBATCH_*` at start ([P6](04-proposals.md#p6)).

<a id="f15"></a>
### F15: Controller resources are hard-coded (Medium)

**Where:** `controller.sh:4-9`; `R/utils.R:40` copies only `account` and `partition`.

- Sites that require `--qos`, `--clusters`, `--constraint`, `--gres`,
  `--reservation` or a minimum memory cannot run the controller at all.
  The failure appears at the first hop, or later if the steps differ.
- Sites that allocate whole nodes make every controller hop cost a whole
  node and wait for one.
- The controller can't be sent to a fast partition or QOS. In the logs
  ([L3](02-log-analysis.md#24-finding-l3-hop-latency-is-normally-about-7-s-but-one-hop-took-1-h-21-m)),
  one hop spent about 1 h 20 m in the queue for a 1-second job, using
  the same six-partition list as the 8-hour steps.
- The controller never gets `--mail-type`, so a controller that fails
  (for example because it can't submit the step) notifies nobody.
- When a step sets `clusters`, its `afterany` dependency points at a
  controller job on another cluster.

**Fix:** a `ctrl_sbatch_opts` argument with today's values as defaults,
plus a default `mail-type=FAIL` when `mail-user` is set ([P10](04-proposals.md#p10)).

<a id="f16"></a>
### F16: Hidden site requirements (Low)

The runtime needs:
- (a) `sbatch` callable from compute nodes. A partition's `AllocNodes`
  setting or a job_submit plugin can forbid it (Appendix B #14).
- (b) the loaded login environment to put `sbatch` on `PATH` in a
  `--export=NONE` job. When loading it fails, Slurm ≥ 25.05 holds the job
  and earlier versions run it with a bare environment (F8).
- (c) the same absolute `SWF_ROOT` path on login and compute nodes
  (`realpath` on the login node, `start_workflow.sh:19`).

All three hold on RSPH and HYAK but are site policy elsewhere. None of
them is documented or checked.

<a id="f17"></a>
### F17: The working-directory contract is implicit, and relative paths are baked in (Medium)

**Where:** `R/step_templates.R:73,119,169` write
`Rscript "workflows/<wf>/SWF/steps/N/script.R"`, relative to wherever R
ran. Every `sbatch` inherits its caller's directory.

Running `start_workflow.sh` from anywhere but the project root (without
`-d`) is accepted. Step 1, often bash such as `git pull`, may even work.
The first R step then fails with a path error. The bash side resolves
`SWF_ROOT` to an absolute path, so the path to the same `script.R` is
available at runtime as `$SWF__CUR_DIR/script.R`, but the generated
instructions don't use it. renv's activation also depends on the working
directory and fails silently (wrong library) instead of loudly.

**Fix:** generate `$SWF__CUR_DIR`-based paths, record the working
directory at start, pass `--chdir` explicitly to every controller, and
check the paths before starting ([P7](04-proposals.md#p7)).

<a id="f28"></a>
### F28: Each job's `SLURM_*` variables leak into the jobs it submits, all the way down the chain (Medium)

**Where:** every nested `sbatch`: `step.sh:54`, `controller.sh:29`.

**Mechanism (Slurm source, Appendix B #12).** `sbatch` copies every
variable whose name starts with `SLURM` from its own environment into
the job it submits, in every `--export` mode including `NONE`. At launch,
Slurm then overwrites only the variables that apply to the new job.
Inside the runtime this means:

- The controller queued by an array's highest-index task inherits that
  task's `SLURM_ARRAY_JOB_ID`, `SLURM_ARRAY_TASK_ID`,
  `SLURM_ARRAY_TASK_MAX`, `SLURM_ARRAY_TASK_COUNT`, … It passes them to
  the next step, and so on. **Every non-array step after the first array
  step runs with a stale copy of that array's variables.** Today's tail
  test (`step.sh:22`) still works only because the stale values come
  from the highest-index task, so `TASK_ID == TASK_MAX`. Anything that
  uses those variables to ask "am I an array task?" is misled: the naive
  version of P2 (a stale array ID as the dependency), a "which task am I"
  check in user code, and P3's expected task count.
- The controller's own `SLURM_MEM_PER_CPU=500`, `SLURM_CPUS_PER_TASK=1`
  and so on leak into each step it submits whenever the step uses a
  different option (`--mem` instead of `--mem-per-cpu`, no
  `cpus-per-task`). `srun` inside the step reads these as defaults, so
  it gets the controller's 500 MB per CPU or a contradictory memory
  setting (inferred from the code, not observed in the logs, since no
  `merck_calib2` step uses `srun`).

**Fix:** remove `SLURM*` variables (except `SLURM_CONF`) from the
environment of every nested `sbatch`:
`env -u SLURM_… sbatch …` ([P2](04-proposals.md#p2), and `swf__clean_sbatch`
in 05).

---

## E. Failure handling and operations

<a id="f9"></a>
### F9: Failures are silent: no record, no notification, no status (High)

**Where:** whole runtime; see the table in
[01-design §1.3](01-design.md#failure-semantics-as-implemented).

When anything fails (an error, time limit, OOM, preemption, `scancel`,
a rejected or failed `sbatch`, a bad next step), the chain simply ends.
Nothing is written to the workflow's log directory saying it ended, where,
or why. The only notification is Slurm's own mail, and only for jobs
whose `--mail-type` covers the event (never the controller). "Is my
workflow still running, and where did it stop?" means `squeue` plus
reading log files.

The `afterany` dependency suggests the chain continues after a failure,
but because the successor is only submitted when the step reaches its
last line, the chain cannot react to a failure.

The reverse is also true: **there is no way to stop a running
workflow**. Once the highest-index task has queued its controller,
`scancel <array>` (the natural way to stop) only satisfies the
controller's `afterany`, and the controller then starts the next step.
The user has to find and cancel the pending `<wf>_controller` job too.
This is undocumented.

**Fix:** a journal of events, a failure check in the controller, and a
status script ([P3](04-proposals.md#p3), [P8](04-proposals.md#p8)). The
structural fix is the pre-submitted controller ([P12](04-proposals.md#p12)).

<a id="f10"></a>
### F10: "Finished" and "invalid step number" are the same thing (Medium)

**Where:** `controller.sh:27-40`.

The run ends when `steps/<N>/job.sh` does not exist. `-s 0`, `-s abc`,
`-s 99`, and `change_next_workflow_step(99)` in a 7-step workflow all end
with `All steps are done` and exit 0. *Reproduced* (`-s abc` is accepted
and submitted). A typo in a jump target is reported as success.

**Fix:** the controller knows the number of steps and only treats
`N + 1` as the end ([P1](04-proposals.md#p1)/[P8](04-proposals.md#p8)).

<a id="f11"></a>
### F11: Restart is coarse (`-s N` only) (Medium)

- No way to pass `sbatch` options at start. Restarting step 6 of
  `merck_calib2` after a failure in slice 5 of a 20-slice map reruns
  slices 1–4.
- No way to rerun only the failed tasks of an array.
- No record of where a run stopped to resume from (see F9). The user
  has to reconstruct which step, and for loops which iteration, from logs.

**Fix:** a journal and a `-o` option first; then a `resume` that reads the
journal and reruns only failed indices ([P8](04-proposals.md#p8), [P12](04-proposals.md#p12)).

<a id="f13"></a>
### F13: One failed `sbatch` kills the workflow; submissions are not idempotent (Medium)

**Where:** `step.sh:54-60`, `controller.sh:29-35`, `start_workflow.sh:75-79`.

- No retry. A transient controller error (`Socket timed out on send/recv
  operation`, `Unable to contact slurm controller`) or a submit-limit
  rejection (`QOSMaxSubmitJobPerUserLimit`) at any of the dozens of hops
  of a calibration ends the run. Each array task counts separately
  against submit limits, so 32×N queued tasks plus a controller can hit
  the limit. sbatch's own retries cover only "queue full", "nodes/ports
  busy" and `EAGAIN`, never a policy rejection (Appendix B #8–9).
- Not idempotent. `Socket timed out on send/recv operation` can be raised
  after the request reached slurmctld, and nothing resends it, so **the
  job may exist even though sbatch reported failure**. Only
  `Unable to contact slurm controller (connect failure)` guarantees that
  nothing was submitted. A requeued job reruns its hand-off from the top
  with the same job ID. Both cases create duplicate chains (F1).
- `sbatch` output isn't captured (`--parsable` isn't used), so job IDs
  aren't recorded anywhere and a stop or status tool can't be built on
  them.

**Fix:** a wrapper that submits once per (run, hop), retries, and records
IDs ([P1](04-proposals.md#p1)).

<a id="f14"></a>
### F14: `start_workflow.sh` argument handling (Medium)

| Input | Result | |
|---|---|---|
| `./start_workflow.sh 3` (forgot `-s`) | **infinite loop** on the login node, no output | *Reproduced* (killed by `timeout`, exit 124). The `case` has no branch for non-option words, so `$1` is never shifted. `POSITIONAL_ARGS` is declared and unused |
| `source start_workflow.sh` | prints the warning, but `set -e` (line 4) has already run in **the user's interactive shell**. The next failing command closes their SSH session. It also returns 0 | *Reproduced:* caller's flags become `ehBc`, and the next `false` exits the caller |
| `-s` with no value | exits 1 silently (the second `shift` fails under `set -e`) | *Reproduced* |
| `-s abc`, `-s 0`, `-s 99` | accepted (see F10) | *Reproduced* |

**Fix:** guard before `set -e`, `getopts`, a `*)` branch, and validation ([P9](04-proposals.md#p9)).

<a id="f20"></a>
### F20: No guard against runaway loops (Low)

A loop whose exit condition is never met (a bug in the user's
convergence test) resubmits forever, two jobs per iteration, until
someone notices. A per-run cap on hops (default very large, configurable)
is a cheap safety net. **Fix:** [P8](04-proposals.md#p8).

---

## F. Next-step transport, temp files, logs

<a id="f12"></a>
### F12: Next-step options are word-split (Medium)

**Where:** `R/sbatch_options.R:21-28` joins the options with spaces;
`step.sh:45` reads them as one string; `controller.sh:32` expands
`${SWF__NEXTSTEP_OPTS}` unquoted.

Any option value with a space (`--comment`, `--export=A=x y`,
`--mail-user` with a display name, …) is split, and the second word
becomes sbatch's *script* argument. *Reproduced:*
`--comment=hello world --array=0-3` is passed as
`[--comment=hello] [world] [--array=0-3] [job.sh]`. Unquoted expansion
also glob-expands values (`--nodelist=node[1-3]` would match a file
literally named like that, which is unlikely but possible).

**Fix:** one option per line, read into a bash array, passed as separate
arguments ([P4](04-proposals.md#p4)).

<a id="f24"></a>
### F24: Next-step files in shared `/tmp`: another user can inject sbatch options, which leads to code execution (High, security, site-dependent)

**Where:** `step.sh:2,10-11` (paths), `step.sh:43-48` (the options file
is read whenever it exists, without an ownership check), `controller.sh:32`
(unquoted expansion), `R/workflow.R:186-197` (the options file is only
touched when `sbatch_opts` is given).

**Scenario.** The files are `$TMP/<jobid>.nextstep[_opts]`, with
`$TMP` usually `/tmp`, a world-writable directory shared by every job on
the node. A running step's job ID and node are visible to everyone in
`squeue`, and a step runs for hours. Another user with a job on the same
node writes `/tmp/<jobid>.nextstep_opts` containing, for example,
`--chdir=/tmp/x --export=ALL,BASH_ENV=/tmp/x/e.sh`. When the victim's step
then calls `change_next_workflow_step(k)` **without** options, which is
exactly what swfcalib does at every calibration iteration, R writes only
the `.nextstep` file. The tail reads the attacker's options file and the
controller submits step `k` with those options:

```
controller -> … --job-name=wf_step3 [--chdir=/tmp/x] [--export=ALL,BASH_ENV=/tmp/x/e.sh] …/steps/3/job.sh
```

*Reproduced* with the real templates and a stub `sbatch`. `BASH_ENV` is
sourced by the batch script's non-interactive bash. Even without it,
`--chdir` alone runs the attacker's code as the victim: R reads
`.Rprofile` from the working directory at start-up, and the generated
`Rscript "workflows/…"` paths are relative (F17).

**Limits.** This needs a malicious user with a job on the same node and
a shared `/tmp`. Sites that give each job a private `/tmp` (for example
`job_container/tmpfs`) or exclusive nodes are not exposed. Pre-creating
the `.nextstep` file instead only blocks the victim's run, because the
victim's `rm`/`file_delete` fails on the sticky directory.

**Also:**
- `.nextstep_opts` is never deleted. Both files are left behind when a
  job fails, and by non-last array tasks (F4.3). *Reproduced.*
- The location prefers the non-standard `SLURM_TMPDIR`, then `TMP`, and
  ignores `TMPDIR`, which is what sites and R (`tempdir()`) use.

**Fix:** a per-task `mktemp -d` directory (mode 0700, unpredictable
name, removed by a trap), and the R side always replacing both files
together ([P5](04-proposals.md#p5), [P4](04-proposals.md#p4)).

<a id="f19"></a>
### F19: Logs can't answer "what happened" (Medium)

See [02 §2.5](02-log-analysis.md#25-finding-l4-the-logs-cant-answer-basic-questions).
In short: the controller log has no timestamps, controller job IDs, run
or hop identity. Step logs have no job ID, host, restart count or exit
status, and bash steps have no timestamps at all. Non-array logs are
named `…_4294967294.out` (`%a` for a non-array job is Slurm's `NO_VAL`).
All controllers of all runs append to one file, and in the duplicated run
their lines interleave. **Fix:** [P8](04-proposals.md#p8).

<a id="f21"></a>
### F21: The CRLF fixer scans and rewrites too much (Low)

**Where:** `lib.sh:29-35`, called at every start.

- It runs `file` on **every** file under the workflow, including `log/`
  (hundreds to tens of thousands of files in big runs) and the `.rds`
  files, at every start.
- It rewrites any file `file` labels CRLF, logs included. `perl -pi`
  replaces the file, so if a log is still being written (a second start
  while a run is live, which is F1's scenario) the running job keeps
  writing to the deleted inode and its output is lost.
- `xargs` without `-0` breaks on paths with spaces. If `file` is not
  installed, the pipeline fails silently inside `local x=$(…)`.
- The root cause is R writing in text mode on Windows (`writeLines()` to a
  path converts `\n` to `\r\n`). Writing in binary mode makes the fixer a
  safety net instead of a requirement.

**Fix:** scope it to `start_workflow.sh` and `SWF/**/*.sh|*.R`, use
NUL-delimited input, and write LF from R ([P9](04-proposals.md#p9), [P11](04-proposals.md#p11)).

<a id="f25"></a>
### F25: Unquoted paths (Low)

`start_workflow.sh:18-19,22` (`dirname $0`, `realpath $SWF_ROOT`,
`basename $0`) and `lib.sh:5` (`basename $SWF_ROOT`). A path with a space
breaks the workflow at start. Rare on clusters and trivial to fix.

---

## G. Throughput

<a id="f18"></a>
### F18: Map slicing runs as a barrier between slices (Medium)

**Where:** `step_tmpl_map.R:20-38`.

Slice `k+1` is submitted only when slice `k` has completely finished, so
every slice ends with a straggler tail during which the allocation drains.
The vignette's "30,000 jobs in chunks of 500" is 60 sequential barriers,
each paying the slowest task of its slice plus two queue waits. When the
limit that slicing works around is `MaxArraySize` (an index limit) rather
than `MaxSubmitJobs`, all slices could be queued at once with an array
throttle (`--array=0-499%N`), or slice `k+1` could be queued when slice
`k` *starts* rather than when it ends. **Fix:** [P12](04-proposals.md#p12).

---

## H. R code that runs on, or writes for, the cluster

<a id="f22"></a>
### F22: R steps run *local* package code against the *HPC* namespace (Medium)

**Where:** `R/step_templates.R:122,172` serialize `what`/`FUN` with
`saveRDS`.

A closure is serialized with its **body**. When the function belongs to
a package, its environment is serialized only as a *reference* to the
namespace. In `merck_calib2` the `.rds` files hold the bodies of
`swfcalib::calibration_step1`, `swfcalib::calibration_step2` and an
`EpiModelHPC` function as they were in the **local** install. On the HPC
those bodies run inside the **HPC's** `swfcalib`/`EpiModelHPC`
namespaces, which are whatever `renv.lock.hpc` installed. If the two
versions differ, old code calls new internals (or the reverse), and the
failure, if any, is subtle. The workflow pins neither version, and
nothing checks them.

**Fix:** accept functions by name (`"swfcalib::calibration_step1"`),
resolved on the HPC, and record and compare package versions
([P11](04-proposals.md#p11)).

<a id="f23"></a>
### F23: Runtime R templates: hidden dependencies, edge cases, noise (Low)

- `step_tmpl_do_call.R` needs `fs` on the HPC, and `step_tmpl_map.R` needs
  `fs` and `slurmworkflow`. Base R (`file.path`) is enough for the
  former, and the slicing could be inlined. The map template also couples
  the workflow directory's bash protocol to whichever `slurmworkflow`
  version is installed on the HPC.
- A map over zero items gives `--array=0--1`, which `sbatch` rejects at
  run time, mid-workflow. A map with no `...` arguments gives `0-Inf`.
  Neither is checked in R.
- `max_array_size = Inf` by default. A 5,000-item map on a site with
  `MaxArraySize = 1001` fails when the controller submits it, possibly
  hours into the workflow.
- Top-level `gc()` auto-prints a table into every log. Use `invisible(gc())`.
- Every array task reads the whole `map.rds` (all items, `MoreArgs`
  included) to use one element. That is 1.8 MB × 32 for `merck_calib2`'s
  step 6, and it grows linearly with the map.
- `make_wf_vars()` builds `SWF__STEPS_OUT` without a `/`
  (`R/env-vars.R:20`). It is unused, but it is a trap for template authors.

<a id="f26"></a>
### F26: R accepts sbatch options the runtime breaks on or silently overrides (Low)

**Where:** `R/sbatch_options.R:135-236` (the allow-list) against
`controller.sh:29-35`.

The allow-list is "every sbatch option", but in a step's `#SBATCH`
header several of them break the chain or are overridden without a
message:

| Option in `sbatch_opts` | Effect at run time |
|---|---|
| `wait` | the controller's `sbatch` blocks until the step ends, while the step waits (`afterany`) for the controller to end. The deadlock lasts until the controller is killed at its 10-minute limit, and only then does the step start |
| `test-only`, `help`, `usage` | nothing is submitted, the controller prints "has been submitted", and the chain stops silently |
| `output`, `job-name`, `dependency` | silently replaced by the controller's command-line values |
| `array`, `export` (map steps) | silently replaced by the template (F8) |
| `chdir` | moves every later step (F6) |
| `wrap`, `parsable`, `batch` | meaningless or conflicting with the generated script |

**Fix:** a deny-list (or a warning for overridden options) in
`validate_sbatch_opts()`.

<a id="f27"></a>
### F27: Round numbers are written in scientific notation (Low)

**Where:** `R/sbatch_options.R:9,23` (`paste0("--", opt, "=", val)`).

R formats `100000` as `1e+05`. `sbatch_opts = list(mem = 100000)`
becomes `#SBATCH --mem=1e+05`, and it stays that way after the
`workflow.yaml` round trip. `sbatch` rejects it, but only when the
controller reaches that step, possibly hours into the run. *Reproduced:*
`mem`/`time` = 100000 → `1e+05`, while 120000 → `120000` (whichever
form is shorter wins). **Fix:** `format(val, scientific = FALSE, trim = TRUE)`
for numbers ([P11](04-proposals.md#p11)), and the start-time
`--test-only` preflight would catch it ([P9](04-proposals.md#p9)).

---

## Checked and found fine

The reviews checked these and found no problem:

- The deployed scripts in `swf_logs` are identical to the templates
  except for the generated `#SBATCH` block. Every `#SBATCH` line comes
  before the first command, so `sbatch` honours them.
- **Map slicing arithmetic** covers every item exactly once. This was
  checked in R for n ∈ {1, 2, 5, 10, 32, 999, 1000, 30000} with several
  `max_array_size` values including 1 and Inf, and end to end in the mock
  for 7 items with `max_array_size = 3` (slices `0-2`, `0-2`, `0-0`).
- Next-step files are named per task job ID: there are no collisions
  between tasks of one array, or between runs.
- `SWF_ROOT` is made absolute and passed as an argument, so the
  framework's own paths don't depend on the working directory. Only the
  generated R paths do (F17).
- The next-step regex correctly rejects `0`, leading zeros and junk.
- Non-array steps stop the workflow on a failing command, as intended
  (outside the holes of F5–F7).
- The guard against `source` does detect sourcing. Its only problem is
  where it sits (F14).
- Append-mode logs with `%A_%a` give one log per step job that survives
  a requeue.
- The CRLF conversion does run before `sbatch` reads files R wrote on
  Windows.
- **In the logs:** no `sbatch` error, timeout, OOM or requeue. Every R
  step has its "Workflow ran for" footer, every step log ends with its
  successor's submission, and no step started before its predecessor
  array had fully finished.

---

## Appendix A: reproductions

All commands use the unmodified templates from `inst/templates/workflow`
and a stub `sbatch` on `PATH` that logs its argv and current directory.

```bash
S=$(mktemp -d); cd "$S"; mkdir bin tmp
cp -r <slurmworkflow>/inst/templates/workflow wf
cat > bin/sbatch <<'EOF'
#!/bin/bash
echo "cwd=$PWD :: $(printf '[%s] ' "$@")" >> "$SBATCH_LOG"; echo "Submitted batch job 999"
EOF
chmod +x bin/sbatch; export PATH=$S/bin:$PATH SBATCH_LOG=$S/sbatch.log TMP=$S/tmp

timeout 2 ./wf/start_workflow.sh 3; echo $?          # F14: 124 → infinite loop
bash -c 'source ./wf/start_workflow.sh; echo "$-"; false; echo unreachable'   # F14: "ehBc", exits
./wf/start_workflow.sh -s abc; cat sbatch.log       # F10: step "abc" accepted

# One step with arbitrary instructions, run the way Slurm would
mkdir -p wf/SWF/steps/1 && cp <slurmworkflow>/inst/templates/step_dir/job.sh wf/SWF/steps/1/
run() { printf '%s\n' "$1" > wf/SWF/steps/1/instructions.sh; : > sbatch.log
        bash wf/SWF/steps/1/job.sh "$S/wf" 1; echo "rc=$?"; cat sbatch.log; }
export SLURM_JOB_ID=1000
run 'exit 0'                     # F5: rc=0 and no sbatch call
run 'cd /tmp'                    # F6: controller submitted with cwd=/tmp
run 'set -u'                     # F7: "SLURM_ARRAY_TASK_ID: unbound variable", rc=1
run 'SWF__CTRL_SCRIPT=/bin/oops' # F7: submits /bin/oops
run 'echo 4 > "$SWF_NEXTSTEP_FILE"; echo "--comment=a b --array=0-3" > "$SWF_NEXTSTEP_OPTS_FILE"'
bash wf/SWF/controller.sh "$S/wf" 4 "--comment=a b --array=0-3"   # F12: [--comment=a] [b] ...
SLURM_JOB_ID=5031 SLURM_ARRAY_JOB_ID=5000 SLURM_ARRAY_TASK_ID=31 SLURM_ARRAY_TASK_MAX=31 \
  run true                       # F2: --dependency=afterany:5031
SLURM_JOB_ID=5007 SLURM_ARRAY_JOB_ID=5000 SLURM_ARRAY_TASK_ID=7 SLURM_ARRAY_TASK_MAX=31 \
  run 'echo 9 > "$SWF_NEXTSTEP_FILE"'; ls tmp     # F4.3/F24: ignored, 5007.nextstep left
SLURM_JOB_ID=8031 SLURM_ARRAY_JOB_ID=8000 SLURM_ARRAY_TASK_ID=31 SLURM_ARRAY_TASK_MAX=31 \
  run 'set -u'                   # F7: "SWF__NEXTSTEP_OPTS: unbound variable", rc=1

# F24: "another user" plants an options file for job 7777; the victim decides without options
echo "--chdir=/tmp/x --export=ALL,BASH_ENV=/tmp/x/e.sh" > tmp/7777.nextstep_opts
SLURM_JOB_ID=7777 run 'echo 3 > "$SWF_NEXTSTEP_FILE"'
#   → controller.sh … [3] [--chdir=/tmp/x --export=ALL,BASH_ENV=/tmp/x/e.sh]
bash wf/SWF/controller.sh "$S/wf" 3 "$(cat tmp/7777.nextstep_opts)"
#   → sbatch … [--chdir=/tmp/x] [--export=ALL,BASH_ENV=/tmp/x/e.sh] …/steps/3/job.sh
```

F4.1 with the package's own R code:

```r
# SWF_NEXTSTEP_FILE=…/42.nextstep SWF_NEXTSTEP_OPTS_FILE=…/42.nextstep_opts SWF_CUR=4
source("R/workflow.R"); source("R/sbatch_options.R")
change_next_workflow_step(get_current_workflow_step(),               # map slicing
  sbatch_opts = list(array = "0-31", export = "SWF__ARRAY_OFFSET=33"))
change_next_workflow_step(3)                                          # user code
# → 42.nextstep: "3"; 42.nextstep_opts: "--array=0-31 --export=SWF__ARRAY_OFFSET=33"

# F8: map offset missing (e.g. SBATCH_EXPORT=ALL in the login environment)
off <- as.numeric(Sys.getenv("SWF__ARRAY_OFFSET"))   # NA
list(1, 2)[[off]]   # NULL, silently
(1:2)[[off]]        # Error: subscript out of bounds

# F27
paste0("--mem=", 100000)   # "--mem=1e+05"
```

---

## Appendix B: Slurm behaviour this review relies on

Each item was checked by a separate agent against SchedMD's source
(`slurm-25.11` branch tip, compared with 20.02 → 25.05 for the parts that
matter) and the versioned documentation, with nothing run on a cluster.
**GH** = `github.com/SchedMD/slurm/blob/ac66a8e6ce98aa12890f2e34b6e6f803ec2defb7`,
**D** = `slurm.schedmd.com/archive/slurm-25.11.8`.

| # | Behaviour | Source | Version notes |
|---|---|---|---|
| 1 | `--export=NONE`: the job gets `SLURM*` (+ SPANK) variables, then slurmd loads the login environment underneath (`opt.get_user_env = true`). sbatch sets `SLURM_EXPORT_ENV` in the job with *no overwrite*, and `srun` inside reads it | GH `src/sbatch/sbatch.c` L462-474, `src/sbatch/opt.c` L924-927, `src/slurmd/slurmd/req.c` L1684-1712; D `sbatch.html#OPT_export` | Man pages 19.05–22.05 wrongly said get-user-env is ignored. 23.02 added `--export=NIL` (no login load). **Login-env load failure: ≥ 25.05 the job is requeued and held; ≤ 24.11 it runs with the passed environment only** |
| 2 | `--export=VAR=val` (no `ALL`/`NONE`): same branch as `NONE`, so `SLURM*` + listed variables + implicit login-env load | `sbatch.c` L467-470, `src/common/env.c` L2589-2627 | unchanged since 20.02 |
| 3 | The last `#SBATCH --export` wins. Precedence is script < `SBATCH_*` env < command line. Directives after the first command are ignored | `src/common/slurm_opt.c` L1384-1391, `opt.c` L393-409, L602-614; D `sbatch.html#SECTION_INPUT-ENVIRONMENT-VARIABLES` | |
| 4 | Starting a task splits it off the pending array record **under a new ID**. The record keeps the ArrayJobId and becomes the last task. The lowest pending index starts first (`bit_ffs`). A task updated or held individually is split early. Cancelling pending tasks moves the ID to the highest remaining index | `src/slurmctld/job_mgr.c` L3466-3531, L19255-19274, L15617-15637; D `job_array.html#env_vars` | 23.02's example (task 1 = ArrayJobId) was wrong, fixed in 23.11 |
| 5 | `afterany:<ArrayJobId>` = whole array. `afterany:<task JobId ≠ ArrayJobId>` = that task only. The task owning the ArrayJobId passing its own `SLURM_JOB_ID` = whole array. `afterany` waits for epilog completion | `src/slurmctld/job_scheduler.c` L3584-3601, L3176-3180, L3328-3334 | |
| 6 | In `--output`, a non-array job gets `%A` = JobId and `%a` = 4294967294 (`NO_VAL`) | `src/common/print_fields.c` L518-539; D `job_array.html#file_names` | `%r` (restart count) added in 25.11 |
| 7 | `JobRequeue=1` by default. Node failure, preemption with REQUEUE, batch-launch failure, prolog failure, login-env failure (25.05+), `RequeueExit` and `scontrol requeue` all requeue. **The script restarts from the top with the same JobId.** `SLURM_RESTART_COUNT` is set only when > 0. `--no-requeue` disables it. Without `--open-mode=append` a restart truncates the log | `job_mgr.c` L3013-3047, `proc_req.c` L2121-2133, `src/common/env.c` L793-796, `src/slurmd/slurmstepd/io.c` L2100-2113; D `slurm.conf.html#OPT_JobRequeue`, `sbatch.html#OPT_requeue` | |
| 8 | "Socket timed out on send/recv operation" can occur *after* the request was sent, and nothing resends it, so the job may exist. "Unable to contact slurm controller (connect failure)" means nothing was sent. sbatch retries only queue-full, nodes/ports-busy and `EAGAIN` (15×). No SchedMD guidance on retrying | `src/common/slurm_protocol_socket.c` L444, `slurm_protocol_api.c` L2224-2320, L753-820, `sbatch.c` L295-327 | |
| 9 | Array tasks count one by one against `MaxSubmitJobs*` (`QOSMaxSubmitJobPerUserLimit`). `MaxArraySize` bounds the largest index (`index < MaxArraySize`, default 1001) | `src/slurmctld/acct_policy.c` L3278-3279, L2072-2084, `slurm_protocol_defs.c` L936 | |
| 10 | `afterany` on a purged job ID is **silently satisfied**. `afterok`/`afternotok` on an unknown ID are rejected at submit | `job_scheduler.c` L3319-3323, L4132-4144 | rejection since 23.02 |
| 11 | `afterok:<ArrayJobId>` needs every task to succeed. With `--kill-on-invalid-dep=yes` a never-satisfiable dependent is cancelled; otherwise it stays pending (DependencyNeverSatisfied) unless `DependencyParameters=kill_invalid_depend` | `job_mgr.c` L1912, L11722-11742 | moved to DependencyParameters in 20.02 |
| 12 | sbatch reads `SBATCH_*` (+ `SLURM_CLUSTERS`, `SLURM_HINT`) as input, **not** `SLURM_EXPORT_ENV`. In every export mode it copies all `SLURM*` variables of its own environment into the new job, and Slurm only re-sets those that apply to it. So **a non-array job submitted from an array task keeps the parent's `SLURM_ARRAY_*`**, and memory/ntasks variables leak the same way (F28) | `opt.c` L182-246, `src/common/proc_args.c` L842-843, `env.c` L1305-1311, `job_mgr.c` L3846-3856 | inference from code |
| 13 | `SLURM_ARRAY_TASK_MAX` = the highest index actually generated (`0-15:4` → 12), fixed at submit time and unaffected by `%` | `job_mgr.c` L3805-3858 | |
| 14 | Submission from compute nodes can be forbidden per partition (`AllocNodes`) or by a job_submit plugin. There is no global switch | `src/slurmctld/partition_mgr.c` L1961-1980; D `slurm.conf.html#OPT_AllocNodes` | |
