# The wrapper contract

What any wrapper around slurmworkflow (the R package, or one in another
language) must uphold. The bash engine (`swf`, `swf.d/*.sh`) is the only
thing that runs between steps. It trusts the files a wrapper writes and
validates little. Everything below is the wrapper's job unless it is marked
**engine checks**.
Items tagged `[planned: Ax]` refer to `edge-case-review.md`: the engine
does not enforce them yet.

A wrapper has up to three roles:

1. **Builder**: writes a workflow directory (once, on the user's computer).
2. **Steerer**: changes the course of a running workflow (from a job, or the
   login node).
3. **Payload runtime**: the code a step runs (R templates, Python scripts...).

## 1. Files: the `.swf` grammar

- UTF-8, LF. Line 1 is exactly `#!swf-v1`. `#` starts a comment line; empty
  lines are ignored.
- Every other line is `key=value`. The key is `[A-Za-z0-9_.-]+`, up to the
  first `=`. The value is the rest of the line, verbatim: no quoting, no
  escaping, no trimming. **A trailing space is part of the value.**
- No newline, CR or NUL inside a value. Keys are unique within a file.
- Numbers are written as plain integers or decimals: `180`, never `180.0`,
  `1e+05` or `TRUE`. Booleans are `1` (or the key is absent).
- Write to a temporary file in the same directory, then rename. Never write
  in place: concurrent readers see half-written files (measured: 37 of 120
  reads failed).
- Never `source` or `eval` a `.swf` file.

**Engine checks:** the header, key syntax, duplicates and `=`, at read time.
The error stops the controller (`invalid_submission`) or `swf`.

## 2. Builder

### Layout

```
<root>/                     name = basename, [A-Za-z][A-Za-z0-9._-]* [planned: B7]
├── swf                     copied from the engine template, executable
└── swf.d/
    ├── lib.sh controller.sh job.sh       copied unmodified
    ├── workflow.swf
    ├── sbatch_rules.swf
    └── steps/<N>_<name>/{step.swf, instructions.sh, ...}
```

- Copy the engine files **unmodified**, from the same slurmworkflow version
  as the rules you write. `swf` must be executable.
- Steps are numbered `1..N` **contiguously**, unpadded. `N` is the build
  order and defines the default successor. Names match
  `^[A-Za-z][A-Za-z0-9_-]*$`, at most 64 characters, unique, never all
  digits. The directory name is the only place a name is stored.
  `[planned: A11, A12]` (`swf start` refuses gaps, duplicates and missing
  files.)
- `instructions.sh` is a bash script run as `bash -e instructions.sh` from
  the directory `swf start` ran in. Any extra files a template needs live in
  the step directory.

### `workflow.swf`

- `opt.<option>`: the workflow defaults. Informational only: the engine
  never applies them. The builder merges them into every step.
- `ctrl.opt.<option>`: options of the controller jobs (typically
  `partition`, `account`). Read by every controller.

### `sbatch_rules.swf`

`valid`, `reserved` and `exclusive.<group>` lists (space-separated option
names). `swf override` uses them to validate and merge;
`[planned: A8]` the controller also uses them to validate options before
submitting. Write the rules of the slurmworkflow version whose engine you
copied. `reserved` must contain `dependency job-name output parsable export
export-file` `[planned: A9 for export]`.

### `step.swf`: a resolved submission

- `opt.<option>=<value>`: **every** sbatch option of the step, already
  merged with the workflow defaults, with exclusive groups resolved (only one
  of `mem`, `mem-per-cpu`, `mem-per-gpu`), long names without `--`, no
  reserved option. The controller passes each line as one argument,
  `--<option>=<value>`, and adds nothing but `--job-name`, `--output`,
  `--parsable` and, for controllers, `--dependency`.
- `next`: three states, all meaningful:
  - absent: run step N+1 next (or end if there is none);
  - `next=<name>`: run that step next (a **name**, never a number);
  - `next=` (empty): end the workflow after this step.
- `data.<key>`: template data, opaque to the engine. Payloads read it
  through `$SWF_SUBMISSION`.
- Never `skip`, `repeat` or `origin.*`: those belong to runtime messages.
  (`skip=1` in a `step.swf` makes the step never run.)

## 3. Steerer

- **Use the `swf` command** (`"$SWF_CMD" next|override ...`, or
  `<root>/swf` from the login node). It resolves names (and numbers
  `[planned: A1]`), merges with the target's submission, applies the rules,
  validates, locks and writes atomically. Writing under `swf.d/run/` by hand
  is unsupported.
- Arguments go to `swf` as separate argv elements. Use the language's argv
  API (`system2(cmd, shQuote(args))` in R, `subprocess.run([...])` in
  Python), never a joined string.
- A non-zero exit from `swf` **must** become an error in the wrapper,
  carrying `swf`'s stderr. Never ignore it, never retry blindly.
- Semantics the wrapper must not hide:
  - **One-shot**: an override applies to the next submission of that step
    only; the next one reverts to `step.swf`.
  - **Aggregation**: several overrides of the same step before it is
    submitted merge (last value per key wins). `--reset` starts from
    `step.swf`.
  - **`next` is last-writer-wins** across all writers of the run
    `[planned: B9 logs replacements]`.
  - `repeat=1` (map continuation) runs the same step again before any
    pending `next`. A later override of that step keeps it `[planned: A5]`.
  - `skip=1` (or a map size of 0) does not submit; the step's `next` (or
    N+1) follows.
  - Messages go to the run in `$SWF_RUN_ID`, else the current run. A stopped
    run refuses them `[planned: A10]`.
- `next` and `override` are **dangerous**: they can loop forever or skip
  work. Document them as such and prefer a static `next` at build time.

## 4. Payload runtime

- **Environment** (`--export=NONE`: nothing else is inherited; load modules
  and set paths in the step's setup lines):
  `SWF_ROOT`, `SWF_NAME`, `SWF_RUN_ID`, `SWF_RUN_DIR`, `SWF_LOG_DIR`,
  `SWF_CMD`, `SWF_CUR` (number), `SWF_CUR_NAME`, `SWF__CUR_DIR`,
  `SWF__INSTRUCTIONS_SCRIPT`, `SWF_SUBMISSION`, plus Slurm's
  (`SLURM_ARRAY_TASK_ID`, ...).
- **`$SWF_SUBMISSION` is the source of truth** for what this job was
  submitted with (the step's `step.swf` or a claimed override). Never read
  `step.swf` to learn the current array size, offset or options.
- **Exit status is the only failure signal.** Non-zero writes a `failed/`
  marker. A payload that catches its own error and exits 0 is a success to
  the engine. Make wrapper runtimes exit non-zero on any uncaught error.
  `[planned: A3]` kills and pre-flight errors also leave a marker.
  `[decision: E]` what the run does after a failure.
- **Arrays**: the engine never numbers items; it only passes
  `SLURM_ARRAY_TASK_ID` (0-based within this submission) and the `data.*`
  keys. The map convention is language-neutral and 0-based:
  `pos = data.map.offset + SLURM_ARRAY_TASK_ID`, valid when
  `0 <= pos < data.map.total`. `data.map.offset` is the number of items
  already handled by earlier slices, not an index. Each runtime converts
  `pos` to its own convention at the last moment: R uses `pos + 1`; Python
  and bash use `pos`. A task with `pos >= total` exits 0 and does nothing.
  Wrappers implementing their own maps use the same keys (`map.n_items`,
  `map.max_array_size`, `map.offset`, `map.total`, all non-negative
  integers) so that `set_map_size()` and `swf override` work the same way
  for every language.
- **Step numbers are positions, not identities.** Refer to steps by name;
  never compute targets with `SWF_CUR ± k`.
- **Run-scoped state** (counters, flags, intermediate files that must not
  survive a restart) goes in `$SWF_RUN_DIR`. A restart is a new run: one
  started again with `swf start -s <step>` begins with an empty
  `$SWF_RUN_DIR`.
- Do not depend on job names or log paths unless you treat them as the
  documented formats: `<wf>_<N>_<name>`, `<wf>_ctrl`,
  `log/<run_id>/<N>_<name>_<job>_<task>.out`.

## 5. What the engine guarantees

- Steps run one at a time. The next controller starts only after **every**
  task of the previous submission has ended (`afterany` on the job ID).
- Each `opt.*` value reaches `sbatch` as exactly one argument (spaces,
  quotes, `*`, `$` included).
- Every decision is recorded in `swf.d/run/<id>/history`: start, submit,
  claim, skip, end, stop, error. `swf status` and `swf log` read it.
- `swf stop` marks the run stopped and cancels its queued jobs. A controller
  of a stopped or replaced run exits without submitting.
- Nothing needs R, Python or `sacct` on the cluster: bash 4.2, coreutils,
  `sbatch`, `squeue`, `scancel`.
