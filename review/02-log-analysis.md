# 2. What the `merck_calib2` logs show

Source: `../swf_logs/merck_calib2/`, a deployed workflow (scripts identical
to the templates at `84e5f11`) and its 304 files: 273 Slurm logs plus the 31 generated scripts and data files.
Every number below was computed from those files. The scripts used are at
the end of this document.

## 2.1 The workflow

| Step | What it runs (from the serialized `.rds`) | sbatch | Control flow |
|---|---|---|---|
| 1 | bash: spack R, `git pull`, `renv::restore()` | 4 cpu, 3 h | |
| 2 | `step_tmpl_do_call_script`: engine sanity check | 1 cpu | |
| 3 | `swfcalib::calibration_step1`: process results, propose | 8 cpu | jumps to 5 when calibration is complete |
| 4 | `step_tmpl_map(swfcalib::calibration_step2)`, 32 batches (`--array=0-31`) | 8 cpu × 32, 5 h | the batch with `batch_num == n_batches` sets next = 3 |
| 5 | `swfcalib::calibration_step3` (wrap-up) | 1 cpu, mail END | |
| 6 | `step_tmpl_map(EpiModelHPC …)`, 32 batches of simulations with the calibrated parameters | 8 cpu × 32, 8 h | |
| 7 | merge into tibbles | 8 cpu, mail END | |

Expected path: `1 → 2 → (3 → 4)×k → 3 → 5 → 6 → 7 → end`.

## 2.2 Finding L1: the whole workflow ran twice, at the same time, on the same state

### Evidence

`log/merck_calib2_controller.out` starts with:

```
Submitted batch job 46585391
Step number 1 has been submitted
Submitted batch job 46585396
Step number 1 has been submitted        ← a second controller for step 1
...
Submitted batch job 46666654
Step number 7 has been submitted
All steps are done
Submitted batch job 46676821
Step number 7 has been submitted        ← and a second step 7
All steps are done
```

Each step log ends with the `Submitted batch job <id>` line of the
controller it queued. Matching each controller ID to the next step job ID
splits the run into two complete, independent chains:

**Chain A**

| step | job id | first start | last end | span | task 31 end | ctrl queued | note |
|---|---|---|---|---|---|---|---|
| 1 | 46585391 | — | — | — | | 46585395 | `git pull` fast-forwards 04286b8..58331fa |
| 2 | 46585397 | 10-29 16:19:21 | 16:19:23 | 3s | | 46585398 | |
| 3 | 46585399 | 16:19:31 | 16:19:32 | 1s | | 46585402 | wave 1, *initialises* calib state |
| 4 | 46585403 (32 tasks) | 16:19:39 | 17:52:39 | 1h33m | 17:52:10 | 46594033 | task 31 sets next = 3 |
| 3 | 46594212 | 17:52:48 | 17:52:50 | 3s | | 46594251 | wave 2 |
| 4 | 46594265 (32 tasks) | 17:53:00 | 19:56:42 | 2h03m | 19:01:19 | 46605284 | |
| 3 | 46617573 | **21:17:43** | 21:17:45 | 3s | | 46617593 | wave 3 (1h21m after step 4 ended, see L3) |
| 4 | 46617600 (32 tasks) | 21:17:52 | 22:39:56 | 1h22m | 22:37:07 | 46642470 | |
| 3 | 46642472 | 22:40:05 | 22:40:09 | 5s | | 46642473 | complete → jump to 5; wave 3 **iteration 1** |
| 5 | 46642474 | 22:40:17 | 22:40:18 | 1s | | 46642475 | wrap-up |
| 6 | 46642476 (32 tasks) | 22:40:25 | 10-30 01:05:44 | 2h25m | 00:50:54 | 46660986 | |
| 7 | 46666654 | 01:05:52 | 01:06:47 | 56s | | 46667365 | merge |

**Chain B**

| step | job id | first start | last end | span | task 31 end | ctrl queued | note |
|---|---|---|---|---|---|---|---|
| 1 | 46585396 | — | — | — | | 46585400 | `git pull`: "Already up to date" |
| 2 | 46585401 | 10-29 16:19:32 | 16:19:34 | 3s | | 46585404 | |
| 3 | 46585414 | 16:32:43 | 16:32:43 | 1s | | 46585471 | wave 1, proposes again (A's batch is running) |
| 4 | 46585472 (32 tasks) | 16:32:51 | 18:22:15 | 1h49m | 18:17:11 | 46602199 | |
| 3 | 46605149 | 18:22:25 | 18:22:25 | 1s | | 46605151 | wave 2 |
| 4 | 46605152 (32 tasks) | 18:22:33 | 21:45:37 | 3h23m | 19:43:27 | 46605603 | |
| 3 | 46625343 | 21:45:45 | 21:45:45 | 1s | | 46625344 | wave 3 |
| 4 | 46625345 (32 tasks) | 21:45:53 | 23:07:56 | 1h22m | 22:44:39 | 46642487 | |
| 3 | 46645742 | 23:08:03 | 23:08:04 | 1s | | 46645759 | complete → 5; wave 3 **iteration 0**; 8 `min/max` warnings |
| 5 | 46645768 | 23:08:12 | 23:08:12 | 1s | | 46645791 | wrap-up, **overwrites A's** |
| 6 | 46645808 (32 tasks) | 23:08:22 | 10-30 01:27:07 | 2h18m | 01:23:49 | 46676818 | writes while A's step 6/7 run |
| 7 | 46676821 | 01:27:17 | 01:28:13 | 57s | | 46676823 | merge, **overwrites A's** |

(The start time is the R banner, so a few seconds after the job started.
Step 1 is pure bash and has no timestamps.)

Counts check: 24 step jobs = exactly 2 × (1 + 1 + 4 + 3 + 1 + 1 + 1) for
steps 1–7 (per chain: four step-3 runs, three step-4 arrays, one of each
other step). Every job belongs to one of the two chains, and nothing else
ran.

### Consequences

1. **Twice the compute.** Allocated cores × measured run time: chain A
   about **1,390 core-hours**, chain B about **1,550 core-hours**. The
   second chain was started on purpose (see "Cause" below). The two
   chains also competed for the same partitions.
2. **Both chains read and wrote the same swfcalib state with no locking.**
   The logs show the interleaving:
   - 16:32:43: chain B's step 3 starts from the state chain A initialised
     13 minutes earlier and, being non-final, saves a new proposal set
     (per `swfcalib::calibration_step1`). Chain A's step-4 tasks 30 and 31
     start at 16:32:39 and 16:32:43 and read the proposals. This is a
     possible torn or mixed read.
   - Each wave was processed twice by both chains, about 30 minutes apart
     (17:52 A / 18:22 B, 21:17 A / 21:45 B, 22:40 A / 23:08 B), and each
     time the batch outputs of the other chain were being written into the
     same directories. For example, chain A's step 3 at 21:17:43 scored
     wave 3 while tasks 18 and 19 of chain B's array 46605152 were still
     running. They ended at 21:44:21 and 21:45:37.
   - The two final step-3 runs disagree. Chain A ends at *wave 3
     iteration 1*. Chain B ends at *wave 3 iteration 0* and emits 8
     `no non-missing arguments to min/max` warnings, meaning it processed
     an empty or partial result set that chain A had already consumed.
   - Chain B's wrap-up (step 5, 23:08) and merge (step 7, 01:27) ran after
     chain A's, so the files left on disk are chain B's. Chain A's step 7
     (01:05) merged a simulation directory that chain B's step 6 was still
     writing (B's tasks ended between 00:52 and 01:27).
   - The calibrated parameter values printed by both wrap-ups are
     identical. The parameters most likely survived, but the calibration
     history (which proposals were assessed in which wave) and the step-6/7
     outputs are a mix of two runs.
3. **Operational advice:** treat `merck_calib2`'s calibration history and
   merged outputs as suspect. Re-run with a single chain, or at least
   check that the merged tibble matches one consistent set of batches,
   before relying on it.

### Cause

**`start_workflow.sh` was run twice, on purpose.** The workflow's author
confirmed this after the first version of this review. It fits the logs:
the second chain is about 10 s behind at step 2 (16:19:21 vs 16:19:32),
and its `git pull` says "Already up to date" because chain A had just
pulled.

The logs alone could not establish it. A requeue of the first controller
after it had submitted step 1 leaves the same trace: the controller
reruns from the top and submits step 1 again into the same append-mode
log. The controller log records no timestamp, no controller job ID, no
`SLURM_RESTART_COUNT`, and nothing identifying the run (L4).

So the runtime did what it was asked to do. What it lacks is a way to do
it visibly: the two runs have no identity, write to the same logs, and
can't be stopped one at a time. The interference in point 2 is a separate
matter. Two chains sharing one swfcalib state need swfcalib to support
that, and it has no locking. What the runtime can do is make a second run
explicit, tell the runs apart, and stop an *accidental* second start or a
requeue from forking the chain (F1 in [03-findings.md](03-findings.md),
P1 in [04-proposals.md](04-proposals.md#p1)).

## 2.3 Finding L2: array steps did wait for every task, because task 31 kept the array's job ID

`step.sh` makes the highest-index task submit the next controller with
`--dependency=afterany:${SLURM_JOB_ID:-$SLURM_ARRAY_JOB_ID}`, which is the
**task's own job ID** (F2). If that ID only covered task 31, the next step
would start as soon as task 31 ended.

The logs show otherwise. In 7 of the 8 arrays the next step started 7–10 s
after the **last task of the array** ended, even when task 31 had finished
long before. The eighth (46594265) is the 1 h 21 m queue-wait outlier of
L3: it is consistent with this, but doesn't prove it.

| array | task 31 ended | last task ended | next step started | gap after task 31 |
|---|---|---|---|---|
| 46605152 (B, step 4) | 19:43:27 | 21:45:37 | 21:45:45 | **2 h 02 m** |
| 46594265 (A, step 4) | 19:01:19 | 19:56:42 | 21:17:43 | 2 h 16 m |
| 46625345 (B, step 4) | 22:44:39 | 23:07:56 | 23:08:03 | 23 m |
| 46642476 (A, step 6) | 00:50:54 | 01:05:44 | 01:05:52 | 15 m |
| 46585472 (B, step 4) | 18:17:11 | 18:22:15 | 18:22:25 | 5 m |
| 46645808 (B, step 6) | 01:23:49 | 01:27:07 | 01:27:17 | 3.5 m |
| 46617600 (A, step 4) | 22:37:07 | 22:39:56 | 22:40:05 | 3 m |
| 46585403 (A, step 4) | 17:52:10 | 17:52:39 | 17:52:48 | 38 s |

So in this run the job ID that task 31 passed to `afterany` was the
array's own ID. Task 31 inherited it because it was the last task to be
split off the pending array record. Slurm starts array tasks in ascending
index order, so this is usual, but it is a property of scheduling order
and not of the code. The verified Slurm semantics and the cases where it
breaks are in F2. The fix is one line: depend on `SLURM_ARRAY_JOB_ID`.

## 2.4 Finding L3: hop latency is normally about 7 s, but one hop took 1 h 21 m

Measured from the end of a step to the start of the next one (R
timestamps, so they include about 3–5 s of `spack load` + R start-up):

- typical hop (controller queued, started, step queued, started): **6–12 s**
  (for example step 2 → 3: 16:19:23.5 → 16:19:31; step 5 → 6: 22:40:18 → 22:40:25)
- outlier: chain A, step 4 (array 46594265, last task 19:56:42) → step 3
  (46617573, started 21:17:43): **1 h 21 m**. The step-3 job ID is only
  20 below the ID of the controller that step 3 queued at 21:17:46, and
  the cluster was allocating roughly 100–300 IDs per minute that evening.
  So step 3 was submitted around 21:17, not at 19:56. Most of the wait was
  therefore the **controller**, a 1-CPU, 10-minute job, sitting in the
  queue on a busy cluster (chain B's 256-core array was running at the
  time).

Every hop pays two scheduling waits. On a quiet cluster the cost is small.
On a busy one the controller's wait is pure overhead, and the controller
cannot be routed to a faster partition or QOS (F15).

## 2.5 Finding L4: the logs can't answer basic questions

Things the logs cannot tell, which would have made L1 easy to diagnose:

| Question | Why it can't be answered |
|---|---|
| Which controller job submitted which step? When? | `controller.out` holds two bare lines per hop: no timestamp, no `$SLURM_JOB_ID` of the controller, no requesting step |
| Was any job requeued? | `SLURM_RESTART_COUNT` is never printed |
| Which host and which job ID did a task run as? | not printed; the file name only has `%A`/`%a` |
| Did a step exit 0? When did step 1 (bash) start or end? | bash steps print nothing; only R templates print a banner and duration |
| Which run does a log line belong to? | there is no run identity at all |

Smaller hygiene issues seen in the files:

- Non-array logs are named `…_4294967294.out`: `%a` for a non-array job
  expands to Slurm's `NO_VAL` (0xFFFFFFFE). This happens 18 times in this
  directory.
- Every R step prints a `gc()` table (top-level auto-print in
  `step_tmpl_*.R`).
- Every step prints renv's "packages recorded in the lockfile are not
  installed". This comes from the project, not slurmworkflow: step 1
  restores `renv.lock.hpc`, while every R session checks `renv.lock`.
  It hides real warnings in 273 files.
- Chain A's step 1 `git pull` fast-forwarded the project (04286b8..58331fa),
  including `R/Z-calibration/workflow-2-swfcalib.R`, the script that
  *generated this workflow*. This is by design (step 1 updates the code),
  but it means the R code that ran on the HPC isn't the code that wrote
  the workflow directory. Together with F22, local and HPC code can drift
  apart within a single run.
- About 17 KB of package start-up banners per array task × 192 tasks.
  Harmless, but it buries the lines that matter (`next workflow step was
  changed to 3`).

## 2.6 Reproducing these numbers

```bash
cd swf_logs/merck_calib2/log
# chains: the controller each step queued (last "Submitted batch job" line)
for f in $(ls merck_calib2_step*.out | sort -t_ -k3,3n -k4,4n); do
  printf '%s -> %s\n' "$f" "$(grep -o 'Submitted batch job [0-9]*' "$f" | tail -1)"
done | grep -vE '_([0-9]|[12][0-9]|30)\.out'
# start / end of every task: "Workflow step starting at" + "Workflow ran for"
grep -A1 -H 'Workflow step starting at' merck_calib2_step4_46605152_*.out
grep -A1 -H 'Workflow ran for'          merck_calib2_step4_46605152_*.out
# diverging final states of the two chains
grep -A2 'Current state' merck_calib2_step3_4664*.out
```

The core-hour figures multiply each task's "Workflow ran for" duration by
its `cpus-per-task` (4/1/8/8/1/8/8 for steps 1–7) and add them up per
chain. Step 1 has no duration and is excluded.
