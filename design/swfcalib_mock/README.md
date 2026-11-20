# Mock: the swfcalib workflow in the proposed `.swf` format

This is the workflow built by `EpiModelHIV-Template`'s
`R/Z-calibration/workflow-2-swfcalib.R` (with `make_em_workflow()` from
`R/hpc_configs.R`), written in the proposed `.swf` format instead of
`workflow.yaml` and baked `#SBATCH` lines. Files only: no engine code.

| Directory | Template | Array |
|---|---|---|
| `steps/1_renv_restore/` | `EpiModelHPC::step_tmpl_renv_restore` (bash only) | no |
| `steps/2_calib_step1/` | `step_tmpl_do_call(swfcalib::calibration_step1)` | no |
| `steps/3_calib_step2/` | `step_tmpl_map(swfcalib::calibration_step2)` | 32 batches (256 sims / 8 cores) |
| `steps/4_calib_step3/` | `step_tmpl_do_call(swfcalib::calibration_step3)` | no |
| `steps/5_calib_output/` | `EpiModelHPC::step_tmpl_netsim_swfcalib_output` | 32 batches (256 reps / 8 cores) |
| `steps/6_calib_merge/` | `EpiModelHPC::step_tmpl_merge_netsim_scenarios_tibble` | no |

## Steps: `steps/<N>_<name>/`

- N is the build order. The name is mandatory and unique, `step_<N>` by
  default, and matches `^[A-Za-z][A-Za-z0-9_-]*$`: never numeric, always a
  safe file name.
- The directory is the only place the name is stored (no `name=` key).
- A name resolves by listing `steps/` and comparing the part after the first
  `_` exactly (N has no `_`); a number by the part before it. A partial match
  is impossible: `calib_step1` never matches `3_x_calib_step1`.
- Everything that refers to a step (`next=`, messages, `swf` commands) uses
  its name; `swf start -s` also takes a number.
- The driver does not name its steps today; the names assume it passes
  `step_name =`. The `mail-user` value is a placeholder.

## The format

- Line 1 is `#!swf-v1`. Other lines starting with `#` are comments; empty
  lines are ignored. Generated files carry no comments.
- Every other line is `key=value`. The key is the text before the first `=`
  (`[A-Za-z0-9_.-]+`); the value is the rest of the line, verbatim: no
  quoting, no escapes, no trimming. Values cannot contain a newline.
- A key appears at most once per file.
- Nothing ever `source`s or `eval`s a `.swf` file.
- Written to a temporary file in the same directory, then renamed.

| Key | Meaning |
|---|---|
| `next` | Name of the step to run after this one. Absent: the step built after it. |
| `opt.<option>` | One sbatch option, passed as `--<option>=<value>`. |
| `ctrl.opt.<option>` | Option for the controller job itself (`workflow.swf`). |
| `data.<template>.<key>` | Template data, opaque to the engine. |
| `skip` | `1`: don't submit this step, go to its `next` (overrides only). |
| `repeat` | `1`: run this step again before honouring `msg/next.swf` (overrides only). |
| `origin.*` | Who wrote a message (step name, Slurm job), for the logs. |

Every `.swf` file the controller submits from is **resolved**: options are
already merged with the defaults and conflicts removed. The controller only
turns `opt.*` lines into separate `sbatch` arguments.

## Files

```
workflows/merck_calib2/
├── swf                          the one entry point: start / stop / status / log, next / override
└── SWF/
    ├── workflow.swf             defaults (builder) + controller options
    ├── sbatch_rules.swf         engine constants: valid options, exclusive groups
    ├── steps/<N>_<name>/step.swf        resolved default submission of the step
    ├── steps/<N>_<name>/instructions.sh the payload (unchanged)
    └── run/
        ├── current.swf          the live run: id, start, first step, stop time
        └── <id>/
            ├── history          one line per event (start, submit, stop)
            ├── msg/next.swf     one-shot: the step to run after the current one
            ├── msg/override/<name>.swf  one-shot: full replacement of that step's next submission
            └── used/<ctrl_job>_{next,override_<name>}.swf  messages claimed by a controller
```

`history` is not a `.swf` file: one event per line, space-separated
`key=value` fields whose values never contain spaces.

Gone compared to today: `start_workflow.sh` (now `swf start`),
`workflow.yaml` (and the `yaml` import), `steps/<N>/job.sh` (one generic
`SWF/job.sh`, with only `--export=NONE` and `--open-mode=append` baked in),
the node-local `SWF_NEXTSTEP_FILE` / `SWF_NEXTSTEP_OPTS_FILE`, and
`--export=SWF__ARRAY_OFFSET`.
Not mocked: `script.R`, `do_call.rds`, `map.rds` (unchanged).

Who writes and who reads:

- **Builder (R today):** writes `workflow.swf` and `steps/<N>_<name>/step.swf`.
- **Any job, any language, or the user on the login node:** writes `msg/`
  files with `swf next <step>` and
  `swf override <step> --opt array=0-15 --data map.total=16 [--skip] [--repeat]`,
  which merge with the target's `step.swf`, apply `sbatch_rules.swf` and
  validate. R's `change_next_workflow_step()` becomes a wrapper around them.
  Writing a message by hand is allowed (it is the documented contract) but
  unchecked.
- **Controller:** reads `workflow.swf` and the steps' `step.swf`, claims
  `msg/` files by moving them to `used/`, appends to `history`.
- **Tasks:** read the file their submission was made from (`$SWF_SUBMISSION`,
  either the step's `step.swf` or a claimed `used/` file), e.g. for
  `data.map.offset` and `data.map.total`.
- **`swf start` / `swf stop`** write `current.swf`; **`swf status` /
  `swf log`** read `history` and the queue.

## What the controller does after step S

1. If `current.swf` names another run or has `stopped=`, exit.
2. If `msg/override/<S>.swf` has `repeat=1`: T = S, use that file.
3. Otherwise T = `next` from `msg/next.swf`, else `next` of the file S was
   submitted from, else the step built after S. Then use
   `msg/override/<T>.swf` if it exists, else T's `step.swf`; if T is empty
   (S was the last step), the workflow is done.
4. If the chosen file has `skip=1`, take its `next` and go back to step 3
   (at most as many times as there are steps).
5. Submit T with the `opt.*` arguments and `$SWF_SUBMISSION`, then the next
   controller with `--dependency=afterany:<T's job id>`; append both to
   `history`.

## The swfcalib loop

- **Back to calibration step 1 after step 2:**
  `steps/3_calib_step2/step.swf` has `next=calib_step1`. This replaces the
  `if (batch_num == n_batches) change_next_workflow_step(cur - 1)` call at the
  end of `swfcalib::calibration_step2()`; `n_batches` is then no longer
  needed in `MoreArgs`.
- **Exit when calibrated:** `calibration_step1()` writes a one-shot
  `next=calib_step3` when `is_calibration_complete()`.
- **Dynamic wave size:** `calibration_step1()` writes an override of
  `calib_step2` with `opt.array` and `data.map.total` set from the wave's
  proposals. `data.map.n_items` (the length of the vector baked into
  `map.rds`) is the hard ceiling: the step must be built with as many items
  as the largest wave.

## Run snapshots (`run_snapshots/<n>/run/` = `SWF/run/` at one moment)

1. `1_started`: just after `swf start`. Nothing pending.
2. `2_calibration_complete`: `calib_step1` (job 4816020) found the
   calibration complete and wrote `msg/next.swf`. Not yet claimed.
3. `3_dynamic_wave_claimed` (proposed use, not current swfcalib):
   `calib_step1` (job 4815377) asked for a 16-batch wave; the controller
   that ran after it (4815378) claimed the override and submitted
   `calib_step2` with `--array=0-15`. The tasks read `data.map.total=16`
   from the claimed file. `history` shows the chain.
4. `4_slice_continuation` (variant with `max_array_size = 20`): the first
   slice ran tasks 0-19; its task 0 wrote the second slice, `--array=0-11`
   from offset 20, with `repeat=1` so that a `msg/next.swf` written by the
   step's own function waits for the last slice.
5. `5_stopped`: `swf stop` during `calib_step2`: `stopped=` in
   `current.swf`, the pending controller and the running array cancelled.

## Open points

- Options without a value (`--requeue`) cannot be written; the current
  package cannot express them either.
- `next` may name a step that does not exist yet when the step is added:
  check at the end of the build, or let the controller stop the workflow.
- `ctrl.opt.*`: only `partition` (and `account` when set) are copied from the
  defaults, as today.
- Job names and log files could carry the directory name
  (`merck_calib2_3_calib_step2_<job>_<task>.out`) instead of `step3`.
