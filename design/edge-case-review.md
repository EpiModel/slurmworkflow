# Edge-case review (2026-11-18)

Four read-only agents (DeepSeek V4.1 Flash, high) probed the branch:
downstream usage, the bash engine, the R API, and a Python wrapper prototype.
Raw reports: `/tmp/opencode/edge_{downstream,engine,rapi,wrapper}/`.
Findings are merged across agents, then sorted by what to do with them. The
bar is "fails clearly", not "cannot fail".

## A. Fix: silent misbehaviour (the run looks fine and is wrong)

| # | Finding | Found by | Fix |
|---|---|---|---|
| A1 | `swf next 3` / `swf override 2` reject numbers, though the spec and the R docs accept them. swfcalib's `cur + 2` / `cur - 1` jumps fail, and the run continues in build order. | all four | Resolve all-digit references in `cmd_next` / `cmd_override`, as `start` and `log` already do. |
| A2 | A failed step no longer stops the workflow: the next controller is already queued with `afterany`. `step_tmpl_renv_restore`'s wrong-branch guard and every `stop()` guard become no-ops. | downstream | **Decision needed**, see section E. |
| A3 | No `failed/` marker when a payload is killed (time limit, SIGTERM) or `job.sh` fails before the payload starts (missing `instructions.sh`, run directory, step). | engine, wrapper | `job.sh`: trap TERM/INT/HUP and route every non-zero exit through one `swf_fail` that writes the marker. |
| A4 | An `squeue` error (purged id, slurmctld hiccup) makes `swf start` think the live run is dead. It starts a second chain that `swf stop` cannot cancel. | engine | An unknown queue state counts as live. Say so, and point to `--force`. |
| A5 | A map `FUN` overriding its own step (`set_map_size`, `override_workflow_step`) drops the pending continuation's `repeat=1`, so the remaining slices never run. | R API | `swf override` keeps `repeat=1` when the pending base has it, unless `--reset`. |
| A6 | A map's `opt.array` overridden so it no longer covers `total - offset` (`0-1` on 5 items, `1,3,5`): items are silently dropped or mis-mapped. | R API | `step_tmpl_map.R` checks `SLURM_ARRAY_TASK_COUNT` against the expected slice and fails otherwise. |
| A7 | List, factor, logical and data.frame values are coerced (`list(2)` becomes `2`, `TRUE` becomes `opt.exclusive=TRUE`). Duplicate option names: the last one wins. | R API | `format_swf_value`: atomic character or numeric only, the key named in the error. Reject duplicate names. |
| A8 | `opt.*` read from files is never validated by the controller (`opt.output=/dev/null`, `opt.=1`, `opt.dependency=...`, which hangs). | engine, wrapper | The controller checks option names against `sbatch_rules.swf` (`valid`, not `reserved`) before submitting; error `invalid_option:<k>`. |
| A9 | `export` / `export-file` are not reserved, so a step can override `job.sh`'s `--export=NONE`. | downstream | Add them to `reserved`. |
| A10 | `next` / `override` on a stopped run succeed and are never consumed. | engine, R API | Error: "run <id> is stopped". |
| A11 | Numbering gaps silently truncate the run (1, 2, 4 ends after 2). Deleting a step directory, then `add_workflow_step()`, creates a duplicate number and bricks the workflow. | engine, R API | `swf start` validates the layout (see A12). R numbers steps max + 1 and refuses a broken layout before creating anything. |
| A12 | A dangling or typo'd static `next` (`next=two ` with a space, `fitt`) is only found mid-run, as a bare `step_not_found`. | R API, engine | New `swf check`, run by `swf start`: contiguous 1..N, unique names, `step.swf` and `instructions.sh` present, every static `next` resolves, every file parses. Refuse to start otherwise. The error reason names the value. |
| A13 | A user `array` option is silently replaced by `step_tmpl_map`'s (the `%k` throttle is lost). | downstream | Error on conflict. Add `step_tmpl_map(..., array_throttle =)`. |
| A14 | `fix_crlf_files` rewrites every text file under the workflow root (user data, logs) at each start. | engine | Restrict it to `swf`, `swf.d/*.sh`, `.swf` files and `instructions.sh`. |

## B. Fix: unclear failure (it stops, but the message does not help)

| # | Finding | Fix |
|---|---|---|
| B1 | A stale `lock/` (killed job): 62 s stall, then the controller dies with no `event=error`. | `controller_error lock_timeout`. The message says a job may have been killed, how to check, and to remove the lock. |
| B2 | Controller error reasons carry no detail (`step_not_found`, `sbatch_failed`). | `reason=step_not_found:<value>`, and the controller log keeps sbatch's stderr. |
| B3 | Map runtime without valid `data.map.*`: `subscript out of bounds` / `missing value where TRUE/FALSE`. | Validate the three keys up front; name the submission file. |
| B4 | `SWF_CMD` not found: `error in running command`. | Check the file exists; the message names `SWF_CMD`. |
| B5 | 0.1.x workflow directories: "SWF file does not exist". | Detect `workflow.yaml` / `start_workflow.sh`: "0.1.x workflow, rebuild it". |
| B6 | A `FUN` / `what` whose environment is the global environment loses its globals at run time. | Build-time warning: pass the objects through `args` / `MoreArgs`. |
| B7 | Misattributed messages: `next_step=TRUE` reported as `step_name`; 300-character names give a raw `ENAMETOOLONG`; `wf_name` is never validated (`"a/b"`, `""`). | Name the argument; cap name length at 64; validate `wf_name` like step names. |
| B8 | `swf status` aborts on an `squeue` error and hides the failed jobs. A failed first `sbatch` leaves a phantom current run. `swf stop` ignores `scancel` failures. | Tolerate and report; no current run until the controller is accepted; report failed cancels. |
| B9 | `swf next` silently replaces a pending next with a different value. | Write a `replace` event to `history` and a warning to stderr (the old engine warned). |
| B10 | Two `swf start` launched in parallel both succeed. | `mkdir` lock around start. |

## C. Document only (behaviour is right, users must know it)

- Job names are `<wf>_<N>_<name>` and `<wf>_ctrl`; logs are
  `log/<run_id>/<N>_<name>_<job>_<task>.out`. Public API, stated in the README.
  The old `_step<N>` patterns (EpiModelHPC doctor, project scripts) match
  nothing now.
- Every `swf start` is a new run, with fresh `run/<id>/` and `log/<id>/`.
- Overrides aggregate, and slices of the same wave inherit the wave's override
  (a continuation is built from the wave's own submission).
- Payloads get a bare environment (`--export=NONE`). State that must not leak
  between runs belongs in `$SWF_RUN_DIR`.
- `opt.*` in `workflow.swf` are builder defaults, not runtime defaults. Only
  `ctrl.opt.*` is read there at run time.

## D. Not worth it (dropped)

- Warning about `MaxArraySize` at build time: the limit is per cluster, and
  `sbatch_failed` (with B2) already says why.
- Warning about large serialized closures: R behaviour, not ours.
- Validating sbatch option *values* (`time=abc`): `sbatch` does it; with B2
  its message reaches the controller log and `history`.
- Detecting payloads that exit 0 on error, 0-based vs 1-based mistakes in a
  wrapper's own code, wrappers reading `step.swf` instead of
  `$SWF_SUBMISSION`: undetectable. They belong in the contract.
- BOM, CRLF, uppercase names, roots with spaces, symlinked roots, `cd` /
  `set -u` in payloads, 40 concurrent overrides: already handled (verified).

## E. Decision needed: what a failed step does

Today every failure is recorded (`failed/`, `swf status`), and the next step
runs anyway. The 0.1 engine stopped by accident, when the last array task
failed. Downstream code (`step_tmpl_renv_restore`, AIDSvu, swfcalib's jump
logic) relies on "a failure stops the workflow".

Proposal: `on_failure` per step, default `stop`. The next controller checks
the finished job's `failed/` markers. If there is one, it writes
`event=error reason=step_failed:<N>_<name>`, submits nothing, and exits 1, so
`mail-type=FAIL` on the controller tells the user. `on_failure = "continue"`
(for example, a map where some tasks may fail) keeps today's behaviour.
