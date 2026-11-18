#!/bin/bash
# End-to-end bash engine tests using only the fake Slurm scheduler.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && realpath .)"
TEMPLATE_DIR="$REPO_ROOT/inst/templates/workflow"
FAKE_BIN="$REPO_ROOT/tests/fake_slurm"
ORIGINAL_PATH="$PATH"
TEST_TMP="${TEST_TMP:-/tmp/opencode/slurmworkflow-test-engine.$$}"
mkdir -p "$TEST_TMP"
TOTAL=0
PASSED=0
FAILED=0

function fail {
  printf '    ASSERTION FAILED: %s\n' "$*" >&2
  exit 1
}

function must {
  "$@" || fail "command failed ($?): $*"
}

function assert_eq {
  local expected="$1" actual="$2" label="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || fail "$label: expected <$expected>, got <$actual>"
}

function assert_contains {
  local text="$1" needle="$2" label="${3:-missing text}"
  [[ "$text" == *"$needle"* ]] || fail "$label: <$needle> not found in <$text>"
}

function assert_not_contains {
  local text="$1" needle="$2" label="${3:-unexpected text}"
  [[ "$text" != *"$needle"* ]] || fail "$label: <$needle> found"
}

function assert_file {
  [[ -f "$1" ]] || fail "file not found: $1"
}

function assert_no_file {
  [[ ! -e "$1" ]] || fail "path should not exist: $1"
}

function assert_grep {
  local pattern="$1" file="$2"
  grep -Fq -- "$pattern" "$file" || fail "pattern <$pattern> not found in $file"
}

function assert_not_grep {
  local pattern="$1" file="$2"
  if grep -Fq -- "$pattern" "$file"; then fail "pattern <$pattern> unexpectedly found in $file"; fi
}

function assert_argv_once {
  local argv_file="$1" expected="$2" argument count=0
  assert_file "$argv_file"
  while IFS= read -r -d '' argument; do
    [[ "$argument" == "$expected" ]] && count=$((count + 1))
  done < "$argv_file"
  assert_eq 1 "$count" "exact argv element <$expected>"
}

function case_init {
  local name="$1"
  CASE="$TEST_TMP/$name"
  mkdir -p "$CASE/fake"
  export FAKE_SLURM_DIR="$CASE/fake"
  export PATH="$FAKE_BIN:$ORIGINAL_PATH"
  export FAKE_SLURM_KEEP_ENV=''
  unset SWF_RUN_ID SWF_CUR_NAME SWF_CUR SLURM_JOB_ID SLURM_ARRAY_JOB_ID SLURM_ARRAY_TASK_ID
  RUN_ID=''
}

function new_workflow {
  local name="$1"
  WF="$CASE/$name"
  mkdir -p "$WF"
  cp -a "$TEMPLATE_DIR/." "$WF/"
  cat > "$WF/swf.d/workflow.swf" <<'EOF'
#!swf-v1
opt.comment=workflow-default
ctrl.opt.partition=test-partition
EOF
  cat > "$WF/swf.d/sbatch_rules.swf" <<'EOF'
#!swf-v1
exclusive.mem=mem mem-per-cpu mem-per-gpu
reserved=dependency job-name output parsable
valid=account array comment cpus-per-task dependency job-name mem mem-per-cpu mem-per-gpu nodelist nodes ntasks output parsable partition time requeue
EOF
}

function write_step {
  local number="$1" name="$2" line key
  shift 2
  local dir="$WF/swf.d/steps/${number}_${name}"
  mkdir -p "$dir"
  printf '#!swf-v1\n' > "$dir/step.swf"
  for line in "$@"; do printf '%s\n' "$line" >> "$dir/step.swf"; done
  cat > "$dir/instructions.sh" <<'EOF'
printf '%s %s %s\n' "$SWF_CUR_NAME" "$SLURM_JOB_ID" "$SWF_SUBMISSION" >> "$SWF_ROOT/runs"
EOF
  chmod +x "$dir/instructions.sh"
}

function write_payload {
  local number="$1" name="$2"
  cat > "$WF/swf.d/steps/${number}_${name}/instructions.sh"
  chmod +x "$WF/swf.d/steps/${number}_${name}/instructions.sh"
}

function start_workflow {
  RUN_ID="$($WF/swf start "$@")" || fail 'swf start failed'
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "bad run id: $RUN_ID"
}

function run_scheduler {
  if ! fake_slurm_run > "$CASE/scheduler.out" 2>&1; then
    cat "$CASE/scheduler.out" >&2
    fail 'fake_slurm_run failed'
  fi
}

function history {
  cat "$WF/swf.d/run/$RUN_ID/history"
}

function last_job_for_step {
  local wanted="$1" line field job='' match=0
  while IFS= read -r line; do
    match=0
    for field in $line; do
      case "$field" in
        "step=$wanted") match=1 ;;
        job=*) job="${field#job=}" ;;
      esac
    done
    (( match )) && STEP_JOB="$job"
  done < "$WF/swf.d/run/$RUN_ID/history"
}

function first_submit_step {
  local line
  line="$(grep ' event=submit ' "$WF/swf.d/run/$RUN_ID/history" | head -n 1)"
  FIRST_SUBMIT=''
  local field
  for field in $line; do [[ "$field" == step=* ]] && FIRST_SUBMIT="${field#step=}"; done
}

# ---------------------------------------------------------------------------
# Fake Slurm unit tests

function test_fake_slurm_unit {
  case_init fake-slurm-unit
  mkdir -p "$CASE/work"
  cd "$CASE/work"
  export UNIT_SECRET='must-not-leak'
  export KEEP_UNIT='kept-value'
  export FAKE_SLURM_KEEP_ENV='KEEP_UNIT'
  cat > array.sh <<'EOF'
#!/bin/bash
printf 'job=%s task=%s array=%s min=%s max=%s count=%s\n' \
  "$SLURM_JOB_ID" "$SLURM_ARRAY_TASK_ID" "$SLURM_ARRAY_JOB_ID" \
  "$SLURM_ARRAY_TASK_MIN" "$SLURM_ARRAY_TASK_MAX" "$SLURM_ARRAY_TASK_COUNT"
printf 'secret=<%s> keep=<%s> exported=<%s> submit=<%s> args=%s\n' \
  "${UNIT_SECRET:-}" "${KEEP_UNIT:-}" "${FROM_EXPORT:-}" "$SLURM_SUBMIT_DIR" "$#"
printf 'names=<%s>/<%s> home=<%s> path=<%s>\n' \
  "$SLURM_JOB_NAME" "$USER" "${HOME:+set}" "${PATH:+set}"
EOF
  ID="$(sbatch --parsable --array=2-4%2 --job-name=unit-array \
    "--output=$CASE/work/out-%x-%A-%a.log" --export=NONE,FROM_EXPORT=yes array.sh)" \
    || fail 'array sbatch failed'
  assert_eq 1000 "$ID" 'first fake job id'
  QUEUE="$(squeue -h -j 1000 -o '%i %T %j')"
  assert_contains "$QUEUE" '1000_2 PENDING unit-array' 'pending array range'
  assert_contains "$QUEUE" '1000_3 PENDING unit-array' 'pending array middle'
  assert_contains "$QUEUE" '1000_4 PENDING unit-array' 'pending array end'
  assert_argv_once "$FAKE_SLURM_DIR/jobs/1000/argv" '--array=2-4%2'

  for SPEC in 0--1 3-1 0-3%0 '1,,2' abc; do
    if sbatch --parsable "--array=$SPEC" array.sh > /dev/null 2> "$CASE/invalid.err"; then
      fail "invalid array accepted: $SPEC"
    fi
    assert_grep 'sbatch: error: Invalid job array specification' "$CASE/invalid.err"
  done

  cat > dependency.sh <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> dependencies-ran
EOF
  A="$(sbatch --parsable dependency.sh A)" || fail 'dependency parent submission failed'
  B="$(sbatch --parsable "--dependency=afterany:$A" dependency.sh B)" || fail 'dependency child submission failed'
  assert_eq 1001 "$A" 'parent id'
  assert_eq 1002 "$B" 'child id'
  must fake_slurm_run --one > "$CASE/run-array.out"
  assert_eq COMPLETED "$(< "$FAKE_SLURM_DIR/jobs/1000/state")" 'array completed'
  assert_eq PENDING "$(< "$FAKE_SLURM_DIR/jobs/$B/state")" 'dependency still pending'
  for TASK in 2 3 4; do
    FILE="$CASE/work/out-unit-array-1000-$TASK.log"
    assert_file "$FILE"
    assert_grep "task=$TASK array=1000 min=2 max=4 count=3" "$FILE"
    assert_grep 'secret=<> keep=<kept-value> exported=<yes>' "$FILE"
    assert_grep "submit=<$CASE/work> args=0" "$FILE"
    assert_grep 'names=<unit-array>/' "$FILE"
  done
  TASK_IDS="$(grep '^job=' "$CASE"/work/out-unit-array-1000-*.log | sed 's/.*job=\([0-9]*\).*/\1/' | sort -u)"
  assert_not_contains "$TASK_IDS" '1000' 'array tasks received distinct execution ids'

  must fake_slurm_run --one > "$CASE/run-parent.out"
  assert_eq COMPLETED "$(< "$FAKE_SLURM_DIR/jobs/$A/state")" 'parent completed'
  assert_eq PENDING "$(< "$FAKE_SLURM_DIR/jobs/$B/state")" 'child waited for parent'
  must fake_slurm_run > "$CASE/run-child.out"
  assert_eq COMPLETED "$(< "$FAKE_SLURM_DIR/jobs/$B/state")" 'child completed'
  assert_eq $'A\nB' "$(< dependencies-ran)" 'dependency execution order'

  cat > directives.sh <<'EOF'
#!/bin/bash
#SBATCH --array=0-9
#SBATCH --job-name=directive-name
printf '%s %s\n' "$SLURM_ARRAY_TASK_ID" "$SLURM_JOB_NAME" > cli-wins
EOF
  C="$(sbatch --parsable --array=7 --job-name=cli-name directives.sh)" || fail 'CLI precedence submission failed'
  assert_eq '7' "$(< "$FAKE_SLURM_DIR/jobs/$C/array_tasks")" 'CLI array wins over directive'
  must fake_slurm_run > "$CASE/run-directives.out"
  assert_eq '7 cli-name' "$(< cli-wins)" 'CLI job name wins over directive'

  D="$(sbatch --parsable dependency.sh SHOULD_NOT_RUN)" || fail 'cancel submission failed'
  must scancel "$D"
  assert_eq CANCELLED "$(< "$FAKE_SLURM_DIR/jobs/$D/state")" 'pending cancellation'
  must scancel 999999 2> "$CASE/cancel.err"
  assert_grep 'unknown job' "$CASE/cancel.err"
  must fake_slurm_run > "$CASE/run-cancel.out"
  assert_not_grep SHOULD_NOT_RUN dependencies-ran

  comma_script="$CASE/work/comma.sh"
  cat > "$comma_script" <<'EOF'
#!/bin/bash
printf '%s/%s/%s/%s\n' "$SLURM_ARRAY_TASK_MIN" "$SLURM_ARRAY_TASK_MAX" \
  "$SLURM_ARRAY_TASK_COUNT" "$SLURM_ARRAY_TASK_ID" >> comma-ran
EOF
  E="$(sbatch --parsable --array=3,1,8 "$comma_script")" || fail 'comma array rejected'
  must fake_slurm_run > "$CASE/run-comma.out"
  assert_grep '1/8/3/1' comma-ran
  assert_grep '1/8/3/3' comma-ran
  assert_grep '1/8/3/8' comma-ran
}

# ---------------------------------------------------------------------------
# Engine scenarios

function test_linear_run {
  case_init linear
  new_workflow wf
  write_step 1 one 'opt.comment=one'
  write_step 2 two 'opt.comment=two'
  write_step 3 three 'opt.comment=three'
  cat > "$WF/swf.d/steps/1_one/instructions.sh" <<'EOF'
printf '%s\n' "$SWF__DIR" > "$SWF_ROOT/internal-dir"
printf 'one\n' >> "$SWF_ROOT/runs"
EOF
  start_workflow -d "$CASE"
  run_scheduler
  assert_grep 'event=end' "$WF/swf.d/run/$RUN_ID/history"
  assert_eq 3 "$(grep -c 'one\|two\|three' "$WF/runs")" 'three step payloads ran'
  assert_eq 3 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'three submissions'
  assert_eq "$WF/swf.d" "$(< "$WF/internal-dir")" 'SWF__DIR points to swf.d'
  STATUS="$(must_capture "$WF/swf" status)"
  assert_contains "$STATUS" "Run: $RUN_ID"
  assert_contains "$STATUS" "Workdir: $CASE"
  assert_contains "$STATUS" 'Last submission: step=3_three'
  assert_contains "$STATUS" 'Queue: not in queue'
  STEPS="$($WF/swf steps)" || fail 'swf steps failed'
  assert_contains "$STEPS" '1 one -'
  assert_contains "$STEPS" '2 two -'
  RUNS="$($WF/swf runs)" || fail 'swf runs failed'
  assert_contains "$RUNS" "$RUN_ID (current)"
}

function must_capture {
  local output
  output="$("$@")" || fail "command failed: $*"
  printf '%s' "$output"
}

function test_static_next_loop {
  case_init static-next
  new_workflow wf
  write_step 1 loop next=loop
  cat > "$WF/swf.d/steps/1_loop/instructions.sh" <<'EOF'
n=0
[[ -f "$SWF_ROOT/count" ]] && n="$(< "$SWF_ROOT/count")"
n=$((n + 1))
printf '%s\n' "$n" > "$SWF_ROOT/count"
if (( n == 3 )); then "$SWF_CMD" next finish; fi
printf '%s\n' loop >> "$SWF_ROOT/runs"
EOF
  write_step 2 finish
  start_workflow
  run_scheduler
  assert_eq 3 "$(< "$WF/count")" 'static loop count'
  assert_eq 4 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'three loop runs plus finish'
  test -n "$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_next.swf' -print -quit)" || fail 'next message was not claimed'
  assert_grep 'event=end' "$WF/swf.d/run/$RUN_ID/history"
}

function test_override_once {
  case_init override-once
  new_workflow wf
  write_step 1 driver
  cat > "$WF/swf.d/steps/1_driver/instructions.sh" <<'EOF'
n=0
[[ -f "$SWF_ROOT/n" ]] && n="$(< "$SWF_ROOT/n")"
n=$((n + 1)); printf '%s\n' "$n" > "$SWF_ROOT/n"
if (( n == 1 )); then
  "$SWF_CMD" override work --opt comment=once --data wave.id=7
elif (( n == 2 )); then
  "$SWF_CMD" next work
else
  "$SWF_CMD" next finish
fi
EOF
  write_step 2 work next=driver 'opt.comment=default'
  cat > "$WF/swf.d/steps/2_work/instructions.sh" <<'EOF'
printf '%s\n' "$SWF_SUBMISSION" >> "$SWF_ROOT/work-submissions"
EOF
  write_step 3 finish
  start_workflow
  run_scheduler
  mapfile -t USED < "$WF/work-submissions"
  assert_eq 2 "${#USED[@]}" 'work ran twice'
  assert_contains "${USED[0]}" '/used/' 'first work submission used override'
  assert_contains "${USED[1]}" '/steps/2_work/step.swf' 'override was one-shot'
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_work.swf' -print -quit)"
  assert_file "$CLAIMED"
  assert_grep 'opt.comment=once' "$CLAIMED"
  assert_grep 'data.wave.id=7' "$CLAIMED"
  assert_grep 'opt.comment=default' "$WF/swf.d/steps/2_work/step.swf"
}

function test_skip {
  case_init skip
  new_workflow wf
  write_step 1 driver
  cat > "$WF/swf.d/steps/1_driver/instructions.sh" <<'EOF'
"$SWF_CMD" override unwanted --skip
EOF
  write_step 2 unwanted
  cat > "$WF/swf.d/steps/2_unwanted/instructions.sh" <<'EOF'
touch "$SWF_ROOT/should-not-exist"
EOF
  write_step 3 wanted
  start_workflow
  run_scheduler
  assert_no_file "$WF/should-not-exist"
  assert_grep 'event=skip step=2_unwanted' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'wanted' "$WF/runs"
}

function test_aggregation_login {
  case_init aggregation-login
  new_workflow wf
  write_step 1 target 'opt.mem-per-cpu=4G' opt.time=20 'opt.comment=default'
  start_workflow
  must "$WF/swf" override target --opt comment=first --data a=1 > /dev/null
  must "$WF/swf" override target --opt mem=8G --data b=2 > /dev/null
  PENDING="$WF/swf.d/run/$RUN_ID/msg/override/target.swf"
  assert_grep 'opt.comment=first' "$PENDING"
  assert_grep 'data.a=1' "$PENDING"
  assert_grep 'data.b=2' "$PENDING"
  assert_grep 'opt.mem=8G' "$PENDING"
  assert_not_grep 'opt.mem-per-cpu=' "$PENDING"
  assert_grep 'opt.time=20' "$PENDING"
  assert_eq 1 "$(grep -c '^opt.comment=' "$PENDING")" 'aggregated option is not duplicated'
  run_scheduler
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_target.swf' -print -quit)"
  assert_grep 'data.a=1' "$CLAIMED"
}

function test_aggregation_array_tasks {
  case_init aggregation-array
  new_workflow wf
  write_step 1 writers opt.array=0-1
  cat > "$WF/swf.d/steps/1_writers/instructions.sh" <<'EOF'
if [[ "$SLURM_ARRAY_TASK_ID" == 0 ]]; then
  "$SWF_CMD" override target --opt comment=from-zero --data owner=zero
else
  "$SWF_CMD" override target --opt mem=12G --data owner.two=one
fi
EOF
  write_step 2 target 'opt.mem-per-cpu=2G'
  start_workflow
  run_scheduler
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_target.swf' -print -quit)"
  assert_grep 'opt.comment=from-zero' "$CLAIMED"
  assert_grep 'data.owner=zero' "$CLAIMED"
  assert_grep 'data.owner.two=one' "$CLAIMED"
  assert_grep 'opt.mem=12G' "$CLAIMED"
  assert_not_grep 'opt.mem-per-cpu=' "$CLAIMED"
}

function test_nasty_option_value {
  case_init nasty-options
  new_workflow wf
  write_step 1 one
  NASTY='spaces "double" '\''single'\'' * $HOME %value #hash'
  export NASTY
  export FAKE_SLURM_KEEP_ENV=NASTY
  cat > "$WF/swf.d/steps/1_one/instructions.sh" <<'EOF'
"$SWF_CMD" override two --opt "comment=$NASTY"
EOF
  write_step 2 two
  start_workflow
  run_scheduler
  last_job_for_step 2_two
  assert_argv_once "$FAKE_SLURM_DIR/jobs/$STEP_JOB/argv" "--comment=$NASTY"
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_two.swf' -print -quit)"
  assert_grep "opt.comment=$NASTY" "$CLAIMED"
}

function test_exclusive_and_invalid {
  case_init rules
  new_workflow wf
  write_step 1 target 'opt.mem-per-cpu=4G' opt.time=30 'opt.comment=keep'
  start_workflow
  must "$WF/swf" override target --opt mem=16G --unset-opt time > /dev/null
  PENDING="$WF/swf.d/run/$RUN_ID/msg/override/target.swf"
  assert_grep 'opt.mem=16G' "$PENDING"
  assert_not_grep 'opt.mem-per-cpu=' "$PENDING"
  assert_not_grep 'opt.time=' "$PENDING"
  if "$WF/swf" override target --opt job-name=evil > /dev/null 2> "$CASE/reserved.err"; then fail 'reserved option accepted'; fi
  assert_grep 'reserved sbatch option' "$CASE/reserved.err"
  if "$WF/swf" override target --opt not-a-real-option=x > /dev/null 2> "$CASE/invalid.err"; then fail 'invalid option accepted'; fi
  assert_grep 'invalid sbatch option' "$CASE/invalid.err"
  assert_grep 'opt.comment=keep' "$PENDING"
  must "$WF/swf" stop
}

function test_failing_task_continues {
  case_init failure
  new_workflow wf
  write_step 1 failer opt.array=0-1
  cat > "$WF/swf.d/steps/1_failer/instructions.sh" <<'EOF'
printf 'task %s ran\n' "$SLURM_ARRAY_TASK_ID" >> "$SWF_ROOT/runs"
if [[ "$SLURM_ARRAY_TASK_ID" == 1 ]]; then exit 23; fi
EOF
  write_step 2 after
  start_workflow
  run_scheduler
  last_job_for_step 1_failer
  MARKER="$WF/swf.d/run/$RUN_ID/failed/${STEP_JOB}_1"
  assert_file "$MARKER"
  assert_eq 23 "$(< "$MARKER")" 'failure exit code'
  assert_no_file "$WF/swf.d/run/$RUN_ID/failed/${STEP_JOB}_0"
  assert_grep 'after' "$WF/runs"
  assert_grep 'event=submit step=2_after' "$WF/swf.d/run/$RUN_ID/history"
  STATUS="$(must_capture "$WF/swf" status)"
  assert_contains "$STATUS" 'Failed jobs (1):'
  assert_contains "$STATUS" "${STEP_JOB}_1"
}

function test_stop_and_force {
  case_init stop-force
  new_workflow wf
  write_step 1 one
  start_workflow
  FIRST_RUN="$RUN_ID"
  FIRST_CTRL="$(sed -n 's/.* event=start .*ctrl=\([0-9]*\).*/\1/p' "$WF/swf.d/run/$RUN_ID/history")"
  if "$WF/swf" start > /dev/null 2> "$CASE/live.err"; then fail 'start accepted a live run'; fi
  assert_grep 'still live' "$CASE/live.err"
  must "$WF/swf" stop
  assert_grep 'stopped=' "$WF/swf.d/run/current.swf"
  assert_eq CANCELLED "$(< "$FAKE_SLURM_DIR/jobs/$FIRST_CTRL/state")" 'pending controller cancelled'
  assert_grep 'event=stop' "$WF/swf.d/run/$FIRST_RUN/history"
  run_scheduler
  assert_eq 0 "$(grep -c ' event=submit ' "$WF/swf.d/run/$FIRST_RUN/history")" 'stopped controller submitted no step'

  # A live run is stopped automatically by --force and replaced with a new run.
  start_workflow
  SECOND_OLD_RUN="$RUN_ID"
  OLD_CTRL="$(sed -n 's/.* event=start .*ctrl=\([0-9]*\).*/\1/p' "$WF/swf.d/run/$RUN_ID/history")"
  start_workflow --force
  [[ "$RUN_ID" != "$SECOND_OLD_RUN" ]] || fail '--force did not create a new run'
  assert_eq CANCELLED "$(< "$FAKE_SLURM_DIR/jobs/$OLD_CTRL/state")" '--force cancelled old controller'
  run_scheduler
  assert_grep 'one' "$WF/runs"
}

function test_log_status {
  case_init log-status
  new_workflow wf
  write_step 1 loop opt.array=0-2 next=loop
  cat > "$WF/swf.d/steps/1_loop/instructions.sh" <<'EOF'
printf 'task=%s run-job=%s\n' "$SLURM_ARRAY_TASK_ID" "$SLURM_ARRAY_JOB_ID" >> "$SWF_ROOT/payloads"
printf 'task=%s run-job=%s\n' "$SLURM_ARRAY_TASK_ID" "$SLURM_ARRAY_JOB_ID"
if [[ "$SLURM_ARRAY_TASK_ID" == 0 ]]; then
  n=0
  [[ -f "$SWF_ROOT/count" ]] && n="$(< "$SWF_ROOT/count")"
  n=$((n + 1)); printf '%s\n' "$n" > "$SWF_ROOT/count"
  if (( n == 2 )); then "$SWF_CMD" next finish; fi
fi
EOF
  write_step 2 finish
  start_workflow
  must "$WF/swf" override finish --opt comment=pending > /dev/null
  must "$WF/swf" next finish > /dev/null
  must fake_slurm_run --one > "$CASE/first-controller.out"
  STATUS="$(must_capture "$WF/swf" status)"
  assert_contains "$STATUS" 'Queue: PENDING=3'
  assert_contains "$STATUS" 'next.swf'
  assert_contains "$STATUS" 'override/finish.swf'
  # Remove the deliberately early next message: the payload tests repeat/next
  # precedence separately, and this test wants two complete array submissions.
  rm "$WF/swf.d/run/$RUN_ID/msg/next.swf"
  run_scheduler
  last_job_for_step 1_loop
  LAST_ARRAY_JOB="$STEP_JOB"
  PATHS="$(must_capture "$WF/swf" log -s loop --path)"
  assert_eq 3 "$(printf '%s\n' "$PATHS" | grep -c .)" 'three array logs for last job'
  assert_contains "$PATHS" "1_loop_${LAST_ARRAY_JOB}_0.out"
  assert_contains "$PATHS" "1_loop_${LAST_ARRAY_JOB}_1.out"
  assert_contains "$PATHS" "1_loop_${LAST_ARRAY_JOB}_2.out"
  FIRST_ARRAY_JOB="$(grep ' event=submit step=1_loop ' "$WF/swf.d/run/$RUN_ID/history" | head -n 1 | sed 's/.* job=\([0-9]*\).*/\1/')"
  assert_not_contains "$PATHS" "1_loop_${FIRST_ARRAY_JOB}_" 'log selects last submission'
  TASK_PATH="$(must_capture "$WF/swf" log -s loop -t 1 --path)"
  assert_contains "$TASK_PATH" "1_loop_${LAST_ARRAY_JOB}_1.out"
  assert_eq 1 "$(printf '%s\n' "$TASK_PATH" | grep -c .)" 'one task log selected'
  LOG_TEXT="$(must_capture "$WF/swf" log -s loop -t 1 -n 20)"
  assert_contains "$LOG_TEXT" 'task=1'
  CONTROLLER_PATH="$(must_capture "$WF/swf" log --path)"
  assert_contains "$CONTROLLER_PATH" "/log/$RUN_ID/controller.out"
}

function test_repeat_precedence {
  case_init repeat-precedence
  new_workflow wf
  write_step 1 loop next=after
  cat > "$WF/swf.d/steps/1_loop/instructions.sh" <<'EOF'
printf '%s\n' "$SWF_SUBMISSION" >> "$SWF_ROOT/submissions"
if [[ ! -f "$SWF_ROOT/once" ]]; then
  touch "$SWF_ROOT/once"
  "$SWF_CMD" next after
  "$SWF_CMD" override loop --repeat --data slice=second
fi
EOF
  write_step 2 after
  start_workflow
  run_scheduler
  NUMBER_SUBMISSIONS="$(wc -l < "$WF/swf.d/run/$RUN_ID/used/"*_next.swf 2>/dev/null || true)"
  assert_eq 2 "$(grep -c ' event=submit step=1_loop ' "$WF/swf.d/run/$RUN_ID/history")" 'repeat ran the step twice'
  test -n "$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_loop.swf' -print -quit)" || fail 'repeat override not claimed'
  SECOND_SUBMISSION="$(tail -n 1 "$WF/submissions")"
  assert_contains "$SECOND_SUBMISSION" '/used/' 'second slice used override'
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_loop.swf' -print -quit)"
  assert_grep 'repeat=1' "$CLAIMED"
  assert_grep 'data.slice=second' "$CLAIMED"
  CLAIMS="$(grep 'event=claim' "$WF/swf.d/run/$RUN_ID/history")"
  FIRST_CLAIM="$(printf '%s\n' "$CLAIMS" | head -n 1)"
  assert_contains "$FIRST_CLAIM" '_override_loop.swf' 'repeat claimed before pending next'
  assert_grep 'event=submit step=2_after' "$WF/swf.d/run/$RUN_ID/history"
}

function test_skip_loop_bound {
  case_init skip-loop
  new_workflow wf
  # skip is documented for overrides. A hand-written default can nevertheless
  # contain it; the controller must reject this malformed static cycle rather
  # than spin forever.
  write_step 1 loop next=loop skip=1
  start_workflow
  run_scheduler
  assert_grep 'event=error' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'reason=skip_loop' "$WF/swf.d/run/$RUN_ID/history"
  [[ "$(grep -c 'event=skip' "$WF/swf.d/run/$RUN_ID/history")" -le 2 ]] || fail 'skip bound exceeded number of steps + 1'
  assert_eq 0 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'skip loop submitted no step'
}

function test_first_step_override_and_selectors {
  case_init first-step
  new_workflow wf-numeric
  write_step 1 one
  write_step 2 chosen 'opt.comment=default'
  write_step 3 three
  start_workflow -s 2
  must "$WF/swf" override chosen --opt comment=first-choice --data selected=yes > /dev/null
  run_scheduler
  first_submit_step
  assert_eq 2_chosen "$FIRST_SUBMIT" 'numeric -s selected step 2'
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_chosen.swf' -print -quit)"
  assert_grep 'opt.comment=first-choice' "$CLAIMED"
  assert_grep 'data.selected=yes' "$CLAIMED"
  assert_not_grep 'step=1_one' "$WF/swf.d/run/$RUN_ID/history"

  case_init first-step-name
  new_workflow wf-name
  write_step 1 one
  write_step 2 two
  write_step 3 named
  start_workflow -s named
  must "$WF/swf" override named --opt comment=named-choice > /dev/null
  run_scheduler
  first_submit_step
  assert_eq 3_named "$FIRST_SUBMIT" 'name -s selected named step'
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_named.swf' -print -quit)"
  assert_grep 'opt.comment=named-choice' "$CLAIMED"
  assert_eq 1 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'only named final step ran'
}

function test_from_reset_and_parser {
  case_init override-base
  new_workflow wf
  write_step 1 target 'opt.comment=default' 'opt.time=10' 'data.original=yes'
  start_workflow
  must "$WF/swf" override target --opt comment=pending --data stale=yes > /dev/null
  must "$WF/swf" override target --reset --opt time=44 > /dev/null
  PENDING="$WF/swf.d/run/$RUN_ID/msg/override/target.swf"
  assert_grep 'opt.comment=default' "$PENDING"
  assert_grep 'opt.time=44' "$PENDING"
  assert_grep 'data.original=yes' "$PENDING"
  assert_not_grep 'data.stale=yes' "$PENDING"

  cat > "$CASE/from.swf" <<'EOF'
#!swf-v1
next=
opt.comment=from-file
data.from=yes
repeat=1
origin.step=old
EOF
  must "$WF/swf" override target --from "$CASE/from.swf" --opt requeue=yes > /dev/null
  assert_grep 'opt.comment=from-file' "$PENDING"
  assert_grep 'data.from=yes' "$PENDING"
  assert_grep 'opt.requeue=yes' "$PENDING"
  assert_not_grep 'repeat=' "$PENDING"
  assert_grep 'origin.step=' "$PENDING"

  # Duplicate keys and malformed values are rejected as data, never executed.
  cat > "$CASE/bad.swf" <<'EOF'
#!swf-v1
opt.comment=one
opt.comment=two
EOF
  if "$WF/swf" override target --from "$CASE/bad.swf" > /dev/null 2> "$CASE/duplicate.err"; then fail 'duplicate .swf key accepted'; fi
  assert_grep 'duplicate key' "$CASE/duplicate.err"
  if "$WF/swf" override target --data $'bad=value\nsecond' > /dev/null 2> "$CASE/newline.err"; then fail 'newline value accepted'; fi
  assert_grep 'newlines are not allowed' "$CASE/newline.err"
  must "$WF/swf" stop
}

function run_test {
  local name="$1" function_name="$2"
  TOTAL=$((TOTAL + 1))
  printf '[ RUN      ] %s\n' "$name"
  if ( "$function_name" ); then
    PASSED=$((PASSED + 1))
    printf '[       OK ] %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '[  FAILED  ] %s\n' "$name"
  fi
}

run_test 'fake Slurm: arrays, argv, dependencies, export, output, cancellation' test_fake_slurm_unit
run_test 'linear workflow runs to end; steps/runs/status' test_linear_run
run_test 'static next loop is exited by swf next' test_static_next_loop
run_test 'override applies once and reverts' test_override_once
run_test 'skip override follows static next' test_skip
run_test 'two login overrides aggregate' test_aggregation_login
run_test 'overrides from two array tasks aggregate' test_aggregation_array_tasks
run_test 'nasty option value is one sbatch argv element' test_nasty_option_value
run_test 'exclusive replacement and reserved/invalid options' test_exclusive_and_invalid
run_test 'failed array task is marked and workflow continues' test_failing_task_continues
run_test 'live start refusal, stop, cancellation, and --force' test_stop_and_force
run_test 'log -s/-t selects last job; pending messages in status' test_log_status
run_test 'repeat takes precedence over pending next' test_repeat_precedence
run_test 'cyclic skip stops at loop bound' test_skip_loop_bound
run_test 'first-step override and numeric/name selectors' test_first_step_override_and_selectors
run_test 'override from/reset and .swf validation' test_from_reset_and_parser

printf '\nTest summary\n'
printf '  Total:  %s\n  Passed: %s\n  Failed: %s\n' "$TOTAL" "$PASSED" "$FAILED"
printf '  Scratch: %s%s\n' "$TEST_TMP" "${BASH_COMPAT:+ (BASH_COMPAT=$BASH_COMPAT)}"
if (( FAILED > 0 )); then
  printf '  Result: FAIL (scratch retained)\n'
  exit 1
fi
rm -rf "$TEST_TMP"
printf '  Result: PASS\n'
