# slurmworkflow runtime review

*2026-10-30, branch `dev` @ `84e5f11`.*

*Revised the same day: the author confirmed that `merck_calib2` was
started twice on purpose. F1 is now High instead of Critical. P1 and the
reference implementation now have `-p`, an explicit way to start a
second run next to the first.*

This review covers the code that runs on the cluster: `start_workflow.sh`,
`SWF/{lib,controller,step}.sh`, `steps/N/job.sh`, the R scripts executed
inside steps (`step_tmpl_do_call.R`, `step_tmpl_map.R`), and
`change_next_workflow_step()`. The R code that generates the workflow is
covered only where it decides what the runtime sees.

**Evidence used:**
- the code;
- reproductions against the real template files with a stub `sbatch`;
- an end-to-end mock-Slurm harness that runs whole generated workflows,
  including arrays, dependencies, requeues, kills and double starts;
- the deployed `merck_calib2` workflow and its 273 Slurm logs (`../swf_logs`);
- Slurm's documentation and source for the semantics the runtime depends on;
- an independent second review that did not see these findings.

| Document | Content |
|---|---|
| [01-design.md](01-design.md) | Goals, components, run-time protocol, failure semantics as built, the 11 unstated assumptions, strengths to keep |
| [02-log-analysis.md](02-log-analysis.md) | What `merck_calib2` actually did: two concurrent chains, array timing, hop latency, log gaps |
| [03-findings.md](03-findings.md) | 28 findings with severity, location, scenario, evidence; what was checked and found fine; Appendix A: reproduction commands; Appendix B: the Slurm behaviour relied on, with source citations |
| [04-proposals.md](04-proposals.md) | Advice for now, Tier 1 fixes (P1–P11), the Tier 2 redesign (P12), testing, rollout |
| [05-reference-implementation.md](05-reference-implementation.md) | Tier 1 as working scripts, and the mock-Slurm results before and after |

## Verdict

The basic design fits the goals. A chain of `sbatch` jobs that rebuilds
itself, with no daemon and with control flow decided at run time, is the
right shape for unbounded loops such as calibration. The code is small and
readable.

Its weakness is that **the runtime has no notion of a run**. It has no
run identity, no state, no lock, and no record of what happened. A
failure ends the chain without a word. And the step's own shell, which
runs arbitrary user code, also performs the hand-off to the next step.
Almost every serious finding follows from one of these three facts.

## The findings that matter most

1. **Two runs of one workflow can't be told apart, and nothing stops an
   accidental one (F1, High).** In `merck_calib2`, two complete chains
   ran in parallel for 9 hours on the same swfcalib state. The second
   start was deliberate, but the logs alone couldn't tell it from a
   requeued controller. The two chains interleaved their reads and
   writes and ended in different calibration states. The surviving
   outputs are chain B's, and chain B processed an empty result set at
   the end. Nothing in the runtime gives a run an identity, or keeps an
   accidental second start or a requeue from forking the chain.
2. **The array hand-off waits for the whole array by accident (F2,
   High).** The hand-off depends on the last task's *own* job ID. It
   covers the whole array only when that task happened to inherit the
   array ID. In the mock with a different start order, the rest of the
   workflow ran before two of the array's tasks had started. The fix is a
   three-line change (P2).
3. **Array failures are handled by index (F3, High).** If the last task
   fails, the workflow stops silently even when the other 31 succeeded. If
   any other task fails, the workflow carries on with partial results.
4. **Stale next-step options (F4, High).** When map slicing and user code
   both choose the next step, the user's step is submitted *as an array
   with the slice's options*. The remaining items are silently skipped,
   and the run ends with "All steps are done".
5. **User instructions can break the hand-off (F5–F7, High/Medium).** An
   `exit 0` silently ends the workflow with success status. A `cd`
   relocates every later step. A `set -u` kills the hand-off.
6. **Failures are silent, and a run can't be stopped (F9, High).**
   Nothing records where or why a run stopped. The `afterany` dependency
   never fires on failure, because the successor is only submitted when
   the step ends normally. Conversely, cancelling a running array doesn't
   stop the workflow, because the queued controller fires anyway.
7. **Another user can inject sbatch options (F24, High, security,
   site-dependent).** The next-step files live in the node's shared
   `/tmp` under names derived from the job ID. On nodes shared between
   users without a private `/tmp`, another user can plant an options file
   (`--chdir=…`, `--export=ALL,BASH_ENV=…`), and it gets used whenever a
   step calls `change_next_workflow_step()` without options. swfcalib does
   that at every iteration. The result is code execution as the workflow's
   owner. The fix is a private `mktemp -d` directory, and it can be
   applied to existing workflow directories today.

Also important (Medium): word-split next-step options; no retry or
idempotency on `sbatch`; an infinite loop when `start_workflow.sh` gets a
positional argument; `source start_workflow.sh` turns on `set -e` in the
user's login shell; hard-coded controller resources; map steps silently
dropping `--export=NONE`, and with `SBATCH_EXPORT=ALL` in a profile,
silently passing `NULL` to the mapped function; every job's `SLURM_*`
variables leaking into the jobs it submits, so every step after an array
carries that array's `SLURM_ARRAY_*` (F28); and R steps running *local*
package code against the *HPC* package namespace.

Two reviews were run independently, this one and a second one that saw
only the code and the logs. Both found the duplicate chain and most of the
High findings. The second review contributed the injection path of F24
and F27. A separate check against SchedMD's source confirmed every Slurm
behaviour the findings rely on, and turned up F28.

## What to do

- **Today, before any code change:** don't trust `merck_calib2`'s
  calibration history and merged outputs. Check the queue before every
  start, and give a deliberate second run its own workflow and swfcalib
  directories. Avoid `exit` and `cd` in step instructions. See
  [04 "Now"](04-proposals.md#now-operational-advice-before-any-code-change).
- **First patch (an hour, no behaviour change except the bug):** P2, a
  three-line change to `step.sh` that depends on `SLURM_ARRAY_JOB_ID` and
  stops the array variables leaking down the chain. Together with P5's
  private temporary directory, it can be applied by hand to existing
  workflow directories.
- **Tier 1 (P1–P11):** keep the topology, and add run identity with
  fencing and an explicit `-p` for a deliberate second run, idempotent
  and retried submissions, per-task results checked by the next
  controller, instructions run in a child shell, a safe next-step
  protocol, a journal with status and stop scripts, and a hardened start
  script. 05 has an implementation of most of it: about
  625 lines of commented bash, against 233 today, including the new
  `stop`/`status` scripts. In the mock Slurm it passes 29 of 30
  scenarios. The 30th is a hard-killed hand-off task, which only the
  status script detects; P12 fixes it. The current templates fail 19 of
  the 30.
- **Tier 2 (P12):** queue the next controller *before* the step runs,
  with `afterany` on it. Every way a step can end is then observed, flow
  logic and slicing live in one place, and only failed array indices need
  rerunning.
