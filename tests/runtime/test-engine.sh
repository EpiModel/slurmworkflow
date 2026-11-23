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
  unset FAKE_SLURM_SQUEUE_FAIL FAKE_SLURM_SCANCEL_FAIL FAKE_SLURM_SBATCH_FAIL
  unset FAKE_SLURM_KILL_AFTER FAKE_SLURM_KILL_NAME SWF_LOCK_TIMEOUT
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
ctrl.opt.mail-user=user@example.org
ctrl.opt.mail-type=FAIL
EOF
  cat > "$WF/swf.d/sbatch_rules.swf" <<'EOF'
#!swf-v1
exclusive.mem=mem mem-per-cpu mem-per-gpu
reserved=dependency job-name output parsable export export-file
valid=account array comment cpus-per-task dependency export export-file job-name mail-type mail-user mem mem-per-cpu mem-per-gpu nodelist nodes ntasks output parsable partition time requeue
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

function test_failed_step_stops {
  case_init failure-stops
  new_workflow wf
  write_step 1 failer opt.array=0-1
  cat > "$WF/swf.d/steps/1_failer/instructions.sh" <<'EOF'
printf 'task %s ran\n' "$SLURM_ARRAY_TASK_ID" >> "$SWF_ROOT/runs"
if [[ "$SLURM_ARRAY_TASK_ID" == 0 ]]; then
  "$SWF_CMD" next after
  "$SWF_CMD" override after --opt comment=pending
fi
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
  assert_not_grep 'after' "$WF/runs"
  assert_not_grep 'event=submit step=2_after' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'reason=step_failed:1_failer failed=1' "$WF/swf.d/run/$RUN_ID/history"
  assert_not_grep 'event=claim' "$WF/swf.d/run/$RUN_ID/history"
  assert_file "$WF/swf.d/run/$RUN_ID/msg/next.swf"
  assert_file "$WF/swf.d/run/$RUN_ID/msg/override/after.swf"
  assert_grep "failed/${STEP_JOB}_1 exit=23" "$WF/log/$RUN_ID/controller.out"
  # The controller that stopped the run exited non-zero (mail-type=FAIL).
  STOPPER="$(sed -n 's/.* event=error by=\([0-9]*\) .*/\1/p' "$WF/swf.d/run/$RUN_ID/history")"
  assert_eq FAILED "$(< "$FAKE_SLURM_DIR/jobs/$STOPPER/state")" 'stopping controller failed'
  assert_argv_once "$FAKE_SLURM_DIR/jobs/$STOPPER/argv" '--mail-type=FAIL'
  STATUS="$(must_capture "$WF/swf" status)"
  assert_contains "$STATUS" 'Failed jobs (1):'
  assert_contains "$STATUS" "${STEP_JOB}_1"
  assert_contains "$STATUS" 'Workflow stopped on error: step_failed:1_failer (failed=1)'
  # The run is over: swf start is allowed without --force.
  start_workflow
}

function test_on_failure_continue {
  case_init failure-continue
  new_workflow wf
  write_step 1 failer opt.array=0-1 on_failure=continue
  cat > "$WF/swf.d/steps/1_failer/instructions.sh" <<'EOF'
printf 'task %s ran\n' "$SLURM_ARRAY_TASK_ID" >> "$SWF_ROOT/runs"
if [[ "$SLURM_ARRAY_TASK_ID" == 1 ]]; then exit 23; fi
EOF
  write_step 2 after
  cat > "$WF/swf.d/steps/2_after/instructions.sh" <<'EOF'
printf 'after\n' >> "$SWF_ROOT/runs"
exit 4
EOF
  write_step 3 never
  start_workflow
  # A login override switches step 2 to continue too; step 3 then runs.
  must "$WF/swf" override after --on-failure continue > /dev/null
  assert_grep 'on_failure=continue' "$WF/swf.d/run/$RUN_ID/msg/override/after.swf"
  if "$WF/swf" override after --on-failure maybe > /dev/null 2> "$CASE/bad.err"; then fail 'bad --on-failure accepted'; fi
  assert_grep 'stop or continue' "$CASE/bad.err"
  run_scheduler
  last_job_for_step 1_failer
  assert_file "$WF/swf.d/run/$RUN_ID/failed/${STEP_JOB}_1"
  assert_grep 'after' "$WF/runs"
  assert_grep 'event=submit step=2_after' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'event=submit step=3_never' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'event=end' "$WF/swf.d/run/$RUN_ID/history"
  assert_not_grep 'event=error' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'on_failure=continue: the workflow goes on.' "$WF/log/$RUN_ID/controller.out"

  # Without the override, the failure of step 2 stops the run before step 3.
  case_init failure-continue-default
  new_workflow wf
  write_step 1 failer opt.array=0-1 on_failure=continue
  cat > "$WF/swf.d/steps/1_failer/instructions.sh" <<'EOF'
if [[ "$SLURM_ARRAY_TASK_ID" == 1 ]]; then exit 23; fi
EOF
  write_step 2 after
  write_payload 2 after <<'EOF'
exit 4
EOF
  write_step 3 never
  start_workflow
  run_scheduler
  assert_grep 'event=submit step=2_after' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'reason=step_failed:2_after failed=1' "$WF/swf.d/run/$RUN_ID/history"
  assert_not_grep 'step=3_never' "$WF/swf.d/run/$RUN_ID/history"
}

function test_term_kill_marker {
  case_init term-kill
  new_workflow wf
  write_step 1 slow
  write_payload 1 slow <<'EOF'
printf 'started\n' >> "$SWF_ROOT/runs"
sleep 30
printf 'not reached\n' >> "$SWF_ROOT/runs"
EOF
  write_step 2 after
  start_workflow
  export FAKE_SLURM_KILL_AFTER=1 FAKE_SLURM_KILL_NAME='wf_1_*'
  SECONDS=0
  run_scheduler
  (( SECONDS < 20 )) || fail "the killed job was not stopped promptly ($SECONDS s)"
  last_job_for_step 1_slow
  MARKER="$WF/swf.d/run/$RUN_ID/failed/$STEP_JOB"
  assert_file "$MARKER"
  assert_eq 143 "$(< "$MARKER")" 'TERM exit code'
  assert_eq TIMEOUT "$(< "$FAKE_SLURM_DIR/jobs/$STEP_JOB/state")" 'job timed out'
  assert_not_grep 'not reached' "$WF/runs"
  assert_grep 'reason=step_failed:1_slow failed=1' "$WF/swf.d/run/$RUN_ID/history"
  assert_not_grep 'step=2_after' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'received SIGTERM' "$WF/log/$RUN_ID/1_slow_${STEP_JOB}_4294967294.out"
  local KILLED
  KILLED="$(tail -n 1 "$WF/log/$RUN_ID/1_slow_${STEP_JOB}_4294967294.out")"
  [[ "$KILLED" =~ ^swf:\ SIGTERM\ +[0-9.]+s\ +\?\ +\?\ +2\ +\?$ ]] || fail "killed time values: $KILLED"
  assert_eq 0 "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'swf-times.*' -newer "$MARKER" 2>/dev/null | wc -l)" 'times file removed'
}

# The last log line reports elapsed, user and system time, like system.time.
function test_payload_time {
  case_init payload-time
  new_workflow wf
  write_step 1 busy
  write_payload 1 busy <<'EOF'
end=$((SECONDS + 1))
while (( SECONDS < end )); do :; done
exit 3
EOF
  start_workflow
  run_scheduler
  last_job_for_step 1_busy
  local LOG="$WF/log/$RUN_ID/1_busy_${STEP_JOB}_4294967294.out" HEAD LAST
  HEAD="$(tail -n 2 "$LOG" | head -n 1)"
  LAST="$(tail -n 1 "$LOG")"
  [[ "$LAST" =~ ^swf:\ 3\ +([0-9]+)\.[0-9]{3}s\ +([0-9]+)\.([0-9]{3})s\ +[0-9]+\.[0-9]{3}s\ +2\ +[0-9]+%$ ]] \
    || fail "unexpected time values: $LAST"
  (( BASH_REMATCH[1] <= 2 )) || fail "elapsed out of range: $LAST"
  # A busy loop of up to 2 s burns user time: at least 0.3 s of it.
  (( 10#${BASH_REMATCH[2]}${BASH_REMATCH[3]} >= 300 )) || fail "user time too low: $LAST"
  local COL NAME
  for NAME in elapsed user system cpus used; do
    COL="${HEAD%%" $NAME"*}"
    [[ "${LAST:${#COL}:1}" == ' ' && "${LAST:${#COL}+1:1}" != ' ' ]] || fail "column $NAME misaligned:\n$HEAD\n$LAST"
  done
  assert_grep 'reason=step_failed:1_busy' "$WF/swf.d/run/$RUN_ID/history"
}

function test_preflight_marker {
  case_init preflight
  new_workflow wf
  write_step 1 one
  write_step 2 two
  start_workflow
  # Deleted after swf check ran: job.sh fails before the payload starts.
  rm "$WF/swf.d/steps/1_one/instructions.sh"
  run_scheduler
  last_job_for_step 1_one
  assert_file "$WF/swf.d/run/$RUN_ID/failed/$STEP_JOB"
  assert_eq 1 "$(< "$WF/swf.d/run/$RUN_ID/failed/$STEP_JOB")" 'pre-flight exit code'
  assert_grep 'instructions not found' "$WF/log/$RUN_ID/1_one_${STEP_JOB}_4294967294.out"
  assert_grep 'reason=step_failed:1_one failed=1' "$WF/swf.d/run/$RUN_ID/history"

  # A bad submission path and an unknown step also leave a marker.
  SLURM_JOB_ID=77 bash "$WF/swf.d/job.sh" "$WF" "$RUN_ID" 2_two "$CASE/missing.swf" 2> "$CASE/job.err" && fail 'job.sh accepted a missing submission'
  assert_grep 'submission not found' "$CASE/job.err"
  assert_eq 1 "$(< "$WF/swf.d/run/$RUN_ID/failed/77")" 'bad submission marker'
  SLURM_JOB_ID=78 bash "$WF/swf.d/job.sh" "$WF" "$RUN_ID" 9_nine "$WF/swf.d/steps/2_two/step.swf" 2> "$CASE/job.err" && fail 'job.sh accepted an unknown step'
  assert_file "$WF/swf.d/run/$RUN_ID/failed/78"
  # A missing run directory cannot hold a marker, but the job still fails.
  SLURM_JOB_ID=79 bash "$WF/swf.d/job.sh" "$WF" no-such-run 2_two "$WF/swf.d/steps/2_two/step.swf" 2> "$CASE/job.err" && fail 'job.sh accepted a missing run'
  assert_grep 'run directory not found' "$CASE/job.err"
  return 0
}

function test_controller_arguments {
  case_init controller-args
  new_workflow wf
  write_step 1 one
  start_workflow
  # The old five-argument after form is refused: the job id is required.
  bash "$WF/swf.d/controller.sh" "$WF" "$RUN_ID" after 1_one "$WF/swf.d/steps/1_one/step.swf" > /dev/null 2> "$CASE/usage.err"
  assert_eq 2 "$?" 'usage exit status'
  assert_grep '<submission> <job_id>' "$CASE/usage.err"
  run_scheduler
  CTRL_JOB="$(sed -n 's/.* event=submit step=1_one job=\([0-9]*\) ctrl=\([0-9]*\).*/\2/p' "$WF/swf.d/run/$RUN_ID/history")"
  STEP_JOB="$(sed -n 's/.* event=submit step=1_one job=\([0-9]*\) .*/\1/p' "$WF/swf.d/run/$RUN_ID/history")"
  ARGS="$(tr '\0' ' ' < "$FAKE_SLURM_DIR/jobs/$CTRL_JOB/args")"
  assert_contains "$ARGS" "after 1_one $WF/swf.d/steps/1_one/step.swf $STEP_JOB" 'controller job id argument'
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
  PATHS="$(must_capture "$WF/swf" log -s loop)"
  assert_eq 3 "$(printf '%s\n' "$PATHS" | grep -c .)" 'three array logs for last job'
  assert_contains "$PATHS" "1_loop_${LAST_ARRAY_JOB}_0.out"
  assert_contains "$PATHS" "1_loop_${LAST_ARRAY_JOB}_1.out"
  assert_contains "$PATHS" "1_loop_${LAST_ARRAY_JOB}_2.out"
  FIRST_ARRAY_JOB="$(grep ' event=submit step=1_loop ' "$WF/swf.d/run/$RUN_ID/history" | head -n 1 | sed 's/.* job=\([0-9]*\).*/\1/')"
  assert_not_contains "$PATHS" "1_loop_${FIRST_ARRAY_JOB}_" 'log selects last submission'
  TASK_PATH="$(must_capture "$WF/swf" log -s loop -t 1)"
  assert_contains "$TASK_PATH" "1_loop_${LAST_ARRAY_JOB}_1.out"
  assert_eq 1 "$(printf '%s\n' "$TASK_PATH" | grep -c .)" 'one task log selected'
  assert_contains "$(cat "$TASK_PATH")" 'task=1'
  CONTROLLER_PATH="$(must_capture "$WF/swf" log)"
  assert_eq "$WF/log/$RUN_ID/controller.out" "$CONTROLLER_PATH" 'controller log path'
}

# A map of 7 elements in slices of 3 (offsets 0, 3, 6) runs twice; `wide` has
# 12 tasks to check the numeric order of the paths.
function test_log_selection {
  case_init log-selection
  new_workflow wf
  write_step 1 map opt.array=0-2 data.map.offset=0 data.map.total=7 next=gate
  write_payload 1 map <<'EOF'
OFFSET="$(sed -n 's/^data\.map\.offset=//p' "$SWF_SUBMISSION")"
printf 'pos=%s\n' $((OFFSET + SLURM_ARRAY_TASK_ID))
if [[ "$SLURM_ARRAY_TASK_ID" == 0 ]] && (( OFFSET + 3 < 7 )); then
  NEXT=$((OFFSET + 3)); SIZE=$(( 7 - NEXT < 3 ? 7 - NEXT : 3 ))
  "$SWF_CMD" override map --repeat --opt "array=0-$((SIZE - 1))" \
    --data "map.offset=$NEXT" --data map.total=7 > /dev/null
fi
EOF
  write_step 2 gate next=wide
  write_payload 2 gate <<'EOF'
if [[ ! -f "$SWF_ROOT/gate" ]]; then touch "$SWF_ROOT/gate"; "$SWF_CMD" next map; fi
EOF
  write_step 3 wide opt.array=0-11 next=
  start_workflow
  run_scheduler
  assert_grep 'event=end' "$WF/swf.d/run/$RUN_ID/history"
  local -a MAP_JOBS=()
  mapfile -t MAP_JOBS < <(grep ' event=submit step=1_map ' "$WF/swf.d/run/$RUN_ID/history" | sed 's/.* job=\([0-9]*\).*/\1/')
  assert_eq 6 "${#MAP_JOBS[@]}" 'two map executions of three slices'
  local LOGS="$WF/log/$RUN_ID"

  # --element finds the slice of the last execution; --back counts executions.
  assert_eq "$LOGS/1_map_${MAP_JOBS[4]}_1.out" "$(must_capture "$WF/swf" log -s map -e 5)" 'element 5'
  local ELEMENT_LOG
  mapfile -t ELEMENT_LOG < "$("$WF/swf" log -s map -e 5)"
  assert_eq 4 "${#ELEMENT_LOG[@]}" 'element 5 log: node line, payload, time table'
  assert_eq "swf: job ${MAP_JOBS[4]}_1 on node fake-node with 2 cpu(s)" "${ELEMENT_LOG[0]}" 'node line'
  assert_eq 'pos=4' "${ELEMENT_LOG[1]}" 'payload output'
  [[ "${ELEMENT_LOG[2]}" =~ ^swf:\ exit\ +elapsed\ +user\ +system\ +cpus\ +used$ ]] || fail "time header: ${ELEMENT_LOG[2]}"
  [[ "${ELEMENT_LOG[3]}" =~ ^swf:\ 0\ + ]] || fail "time values: ${ELEMENT_LOG[3]}"
  assert_eq "$LOGS/1_map_${MAP_JOBS[5]}_0.out" "$(must_capture "$WF/swf" log --step map --element 7)" 'element 7'
  assert_eq "$LOGS/1_map_${MAP_JOBS[3]}_2.out" "$(must_capture "$WF/swf" log -s map -e 3 -b 0)" 'element 3'
  assert_eq "$LOGS/1_map_${MAP_JOBS[0]}_2.out" "$(must_capture "$WF/swf" log -s map -e 3 -b 1)" 'element 3, previous execution'
  assert_eq "$LOGS/1_map_${MAP_JOBS[1]}_1.out" "$(must_capture "$WF/swf" log -s map -e 5 --back 1)" 'element 5, previous execution'
  if "$WF/swf" log -s map -e 5 -b 2 > /dev/null 2> "$CASE/err"; then fail 'accepted --back beyond the executions'; fi
  assert_grep 'too far' "$CASE/err"
  if "$WF/swf" log -s map -e 8 > /dev/null 2> "$CASE/err"; then fail 'accepted an element beyond the map'; fi
  assert_grep 'beyond the 7 items' "$CASE/err"
  if "$WF/swf" log -s gate -e 1 > /dev/null 2> "$CASE/err"; then fail 'accepted --element on a non-map step'; fi
  assert_grep 'not a map slice' "$CASE/err"

  # Submissions: the last by default, --back n before it, --all for every one.
  assert_eq "$LOGS/1_map_${MAP_JOBS[5]}_0.out" "$(must_capture "$WF/swf" log -s map)" 'last slice'
  assert_eq "$(printf '%s\n' "$LOGS/1_map_${MAP_JOBS[4]}_"{0,1,2}.out)" \
    "$(must_capture "$WF/swf" log -s map -b 1)" 'previous slice'
  assert_eq "$LOGS/1_map_${MAP_JOBS[3]}_2.out" "$(must_capture "$WF/swf" log --step=map --back=2 --task=2)" 'long options with ='
  assert_eq 14 "$(must_capture "$WF/swf" log -s map --all | grep -c .)" 'every map log'
  assert_eq 6 "$(must_capture "$WF/swf" log -s map -a -t 0 | grep -c .)" 'task 0 of every submission'
  if "$WF/swf" log -s map -b 6 > /dev/null 2> "$CASE/err"; then fail 'accepted --back beyond the submissions'; fi
  assert_grep 'has 6 submission(s)' "$CASE/err"

  # Paths are in numeric task order.
  last_job_for_step 3_wide
  assert_eq "$(printf "$LOGS/3_wide_${STEP_JOB}_%s.out\n" {0..11})" "$(must_capture "$WF/swf" log -s wide)" 'numeric task order'

  # Argument errors exit 2.
  local args
  for args in '-t 0' '-s map -t 0 -e 1' '-s map -a -b 1' '-s map -e 0' '-s map -b x' '-s' '--path'; do
    # shellcheck disable=SC2086
    "$WF/swf" log $args > /dev/null 2>&1 && fail "accepted: swf log $args"
    assert_eq 2 "$?" "exit status of: swf log $args"
  done
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
  RUN_ID="$("$WF/swf" start -s 2 2> "$CASE/start.err")" || fail 'swf start -s 2 failed'
  assert_grep 'swf: starting at step "chosen" (2), controller job ' "$CASE/start.err"
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "stdout is not only the run id: $RUN_ID"
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

function test_squeue_failure {
  case_init squeue-failure
  new_workflow wf
  write_step 1 one
  start_workflow
  FIRST_RUN="$RUN_ID"
  CURRENT_BEFORE="$(< "$WF/swf.d/run/current.swf")"
  if FAKE_SLURM_SQUEUE_FAIL=1 "$WF/swf" start > /dev/null 2> "$CASE/start.err"; then fail 'start ignored an unknown queue state'; fi
  assert_grep 'cannot query the queue' "$CASE/start.err"
  assert_grep 'Unable to contact slurm controller' "$CASE/start.err"
  assert_grep 'swf start --force' "$CASE/start.err"
  assert_eq "$CURRENT_BEFORE" "$(< "$WF/swf.d/run/current.swf")" 'current run unchanged'
  assert_eq 1 "$(find "$WF/swf.d/run" -mindepth 1 -maxdepth 1 -type d | wc -l)" 'no second run directory'
  # swf status survives the failure and still shows the failures.
  must fake_slurm_run --one > /dev/null
  printf '9\n' > "$WF/swf.d/run/$RUN_ID/failed/4242"
  STATUS="$(FAKE_SLURM_SQUEUE_FAIL=1 "$WF/swf" status 2>&1)" || fail 'status failed when squeue failed'
  assert_contains "$STATUS" 'Queue: unknown: slurm_load_jobs error'
  assert_contains "$STATUS" 'Failed jobs (1): 4242'
  assert_contains "$STATUS" 'Last history:'
  # --force still replaces the run.
  RUN_ID="$(FAKE_SLURM_SQUEUE_FAIL=1 "$WF/swf" start --force 2> /dev/null)" || fail 'start --force failed'
  [[ "$RUN_ID" != "$FIRST_RUN" ]] || fail '--force did not create a new run'
}

function test_squeue_purged_ids {
  case_init squeue-purged
  new_workflow wf
  write_step 1 boom
  write_step 2 after
  write_payload 1 boom <<'EOF'
exit 4
EOF
  start_workflow
  must fake_slurm_run > /dev/null
  assert_grep 'reason=step_failed:1_boom' "$WF/swf.d/run/$RUN_ID/history"
  # Every id of the finished run is purged: squeue fails with "Invalid job id".
  STATUS="$(FAKE_SLURM_SQUEUE_PURGED=1 "$WF/swf" status 2>&1)" || fail 'status failed on purged ids'
  assert_contains "$STATUS" 'Queue: not in queue'
  OLD_RUN="$RUN_ID"
  RUN_ID="$(FAKE_SLURM_SQUEUE_PURGED=1 "$WF/swf" start 2> "$CASE/start.err")" || fail 'start refused a run whose jobs were purged'
  [[ "$RUN_ID" != "$OLD_RUN" ]] || fail 'no new run'
  must "$WF/swf" stop
}

function test_self_override_keeps_continuation {
  case_init keep-continuation
  new_workflow wf
  write_step 1 loop 'data.map.offset=0' 'data.map.total=6' 'next='
  write_payload 1 loop <<'EOF'
printf '%s\n' "$SWF_SUBMISSION" >> "$SWF_ROOT/submissions"
if [[ ! -f "$SWF_ROOT/once" ]]; then
  touch "$SWF_ROOT/once"
  # The continuation, then the payload's own override of its step.
  "$SWF_CMD" override loop --repeat --from "$SWF_SUBMISSION" --opt array=0-1 --data map.offset=4
  "$SWF_CMD" override loop --opt time=7 --opt array=0-9 --data map.offset=0 --data extra=yes 2>> "$SWF_ROOT/notes"
fi
EOF
  start_workflow
  run_scheduler
  assert_eq 2 "$(grep -c ' event=submit step=1_loop ' "$WF/swf.d/run/$RUN_ID/history")" 'continuation ran'
  CLAIMED="$(find "$WF/swf.d/run/$RUN_ID/used" -name '*_override_loop.swf' -print -quit)"
  assert_file "$CLAIMED"
  assert_grep 'repeat=1' "$CLAIMED"
  assert_grep 'opt.array=0-1' "$CLAIMED"
  assert_grep 'data.map.offset=4' "$CLAIMED"
  assert_grep 'data.map.total=6' "$CLAIMED"
  assert_grep 'opt.time=7' "$CLAIMED"
  assert_grep 'data.extra=yes' "$CLAIMED"
  assert_not_grep 'opt.array=0-9' "$CLAIMED"
  assert_grep 'pending continuation (repeat=1)' "$WF/notes"

  # --reset drops the continuation.
  case_init keep-continuation-reset
  new_workflow wf
  write_step 1 loop 'opt.array=0-3' 'data.map.offset=0'
  start_workflow
  must "$WF/swf" override loop --repeat --opt array=0-1 --data map.offset=4 > /dev/null
  must "$WF/swf" override loop --reset --opt time=3 > /dev/null
  PENDING="$WF/swf.d/run/$RUN_ID/msg/override/loop.swf"
  assert_not_grep 'repeat=' "$PENDING"
  assert_grep 'opt.array=0-3' "$PENDING"
  must "$WF/swf" stop
}

function test_invalid_option_at_runtime {
  case_init invalid-option
  new_workflow wf
  write_step 1 one
  write_step 2 two
  start_workflow
  # Edited after swf check: the controller validates before submitting.
  printf 'opt.output=/dev/null\n' >> "$WF/swf.d/steps/2_two/step.swf"
  run_scheduler
  assert_grep 'reason=invalid_option:opt.output' "$WF/swf.d/run/$RUN_ID/history"
  assert_not_grep 'event=submit step=2_two' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'reserved sbatch option: output' "$WF/log/$RUN_ID/controller.out"

  for BAD in 'opt.=1' 'opt.export=ALL' 'opt.time=' 'opt.bogus=1' 'skip=yes' 'repeat=2' 'on_failure=maybe'; do
    case_init "invalid-option-${BAD%%=*}"
    new_workflow wf
    write_step 1 one
    start_workflow
    printf '%s\n' "$BAD" >> "$WF/swf.d/steps/1_one/step.swf"
    run_scheduler
    assert_eq "reason=invalid_option:${BAD%%=*}" "$(grep -o 'reason=[^ ]*' "$WF/swf.d/run/$RUN_ID/history" | tail -n 1)" "reason for $BAD"
    assert_eq 0 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" "nothing submitted for $BAD"
  done

  # An override built --from a file is checked too (opt.dependency would hang).
  case_init invalid-option-from
  new_workflow wf
  write_step 1 one
  start_workflow
  printf '#!swf-v1\nopt.dependency=afterany:999999\n' > "$CASE/from.swf"
  must "$WF/swf" override one --from "$CASE/from.swf" > /dev/null
  run_scheduler
  assert_grep 'reason=invalid_option:opt.dependency' "$WF/swf.d/run/$RUN_ID/history"
  assert_eq 0 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'nothing submitted for dependency'
}

function test_sbatch_failure_detail {
  case_init sbatch-detail
  new_workflow wf
  write_step 1 one
  start_workflow
  cat > "$CASE/from.swf" <<'EOF'
#!swf-v1
opt.array=abc
EOF
  must "$WF/swf" override one --from "$CASE/from.swf" > /dev/null
  run_scheduler
  assert_grep 'reason=sbatch_failed:1_one' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'sbatch stderr:' "$WF/log/$RUN_ID/controller.out"
  assert_grep 'Invalid job array specification' "$WF/log/$RUN_ID/controller.out"

  case_init step-not-found-detail
  new_workflow wf
  write_step 1 one
  write_step 2 two
  start_workflow
  must fake_slurm_run --one > /dev/null
  # Hand-written message with a trailing space: the reason shows it.
  printf '#!swf-v1\nnext=two \n' > "$WF/swf.d/run/$RUN_ID/msg/next.swf"
  run_scheduler
  assert_grep 'reason=step_not_found:two%20' "$WF/swf.d/run/$RUN_ID/history"
  STATUS="$(must_capture "$WF/swf" status)"
  assert_contains "$STATUS" 'Workflow stopped on error: step_not_found:two%20'
}

function test_messages_stopped_run {
  case_init stopped-run
  new_workflow wf
  write_step 1 one
  write_step 2 two
  start_workflow
  OLD_RUN="$RUN_ID"
  must "$WF/swf" stop
  if "$WF/swf" next two > /dev/null 2> "$CASE/next.err"; then fail 'next accepted on a stopped run'; fi
  assert_grep "run $RUN_ID is stopped" "$CASE/next.err"
  if "$WF/swf" override two --opt time=1 > /dev/null 2> "$CASE/override.err"; then fail 'override accepted on a stopped run'; fi
  assert_grep "run $RUN_ID is stopped" "$CASE/override.err"
  assert_no_file "$WF/swf.d/run/$RUN_ID/msg/next.swf"
  assert_no_file "$WF/swf.d/run/$RUN_ID/msg/override/two.swf"
  if SWF_RUN_ID=no-such-run "$WF/swf" next two > /dev/null 2> "$CASE/missing.err"; then fail 'next accepted a missing run'; fi
  assert_grep 'run not found: no-such-run' "$CASE/missing.err"
  # A replaced run refuses messages too, even through SWF_RUN_ID.
  start_workflow
  if SWF_RUN_ID="$OLD_RUN" "$WF/swf" next two > /dev/null 2> "$CASE/old.err"; then fail 'next accepted on a replaced run'; fi
  assert_grep "run $OLD_RUN is stopped" "$CASE/old.err"
  must "$WF/swf" next two > /dev/null 2>&1
}

function test_numeric_references {
  case_init numeric-refs
  new_workflow wf
  write_step 1 one
  write_step 2 two 'opt.comment=default'
  write_step 3 three
  start_workflow
  OUT="$("$WF/swf" next 3 2> "$CASE/next.err")" || fail 'swf next 3 failed'
  assert_grep 'swf: note: step 3 is three; prefer names' "$CASE/next.err"
  assert_grep 'next=three' "$WF/swf.d/run/$RUN_ID/msg/next.swf"
  OUT="$("$WF/swf" override 2 --opt comment=numeric 2> "$CASE/override.err")" || fail 'swf override 2 failed'
  assert_grep 'swf: note: step 2 is two; prefer names' "$CASE/override.err"
  assert_grep 'opt.comment=numeric' "$WF/swf.d/run/$RUN_ID/msg/override/two.swf"
  if "$WF/swf" next 9 > /dev/null 2> "$CASE/nine.err"; then fail 'unknown number accepted'; fi
  assert_grep 'unknown step: 9' "$CASE/nine.err"
  must "$WF/swf" stop
}

function test_next_replace_event {
  case_init next-replace
  new_workflow wf
  write_step 1 one
  write_step 2 two
  write_step 3 three
  start_workflow
  must "$WF/swf" next two > /dev/null 2> "$CASE/first.err"
  assert_eq '' "$(< "$CASE/first.err")" 'no warning for a first next'
  must "$WF/swf" next two > /dev/null 2> "$CASE/same.err"
  assert_eq '' "$(< "$CASE/same.err")" 'no warning for the same next'
  must "$WF/swf" next three > /dev/null 2> "$CASE/replace.err"
  assert_grep 'replacing the pending next step two with three' "$CASE/replace.err"
  assert_grep 'event=replace old=two new=three' "$WF/swf.d/run/$RUN_ID/history"
  assert_eq 1 "$(grep -c 'event=replace' "$WF/swf.d/run/$RUN_ID/history")" 'one replace event'
  must "$WF/swf" stop
}

function test_check_and_start_refusal {
  case_init check-ok
  new_workflow wf
  write_step 1 one next=two
  write_step 2 two on_failure=continue
  OUT="$(must_capture "$WF/swf" check)"
  assert_eq 'ok: 2 steps' "$OUT" 'check passes'

  case_init check-bad
  new_workflow wf
  write_step 1 one 'next=nope'
  write_step 1 dup
  write_step 3 three 'on_failure=maybe' 'opt.export=ALL'
  write_step 4 four 'next=one '
  write_step 5 five
  rm "$WF/swf.d/steps/5_five/instructions.sh"
  mkdir -p "$WF/swf.d/steps/6_six" "$WF/swf.d/steps/x_bad" "$WF/swf.d/steps/07_zero"
  printf '#!swf-v1\nnext=one\nnext=two\n' > "$WF/swf.d/steps/6_six/step.swf"
  printf 'true\n' > "$WF/swf.d/steps/6_six/instructions.sh"
  if "$WF/swf" check > /dev/null 2> "$CASE/check.err"; then fail 'swf check passed a broken workflow'; fi
  CHECK="$(< "$CASE/check.err")"
  assert_contains "$CHECK" "steps/1_one/step.swf: next='nope' is not a step name"
  assert_contains "$CHECK" "steps/4_four/step.swf: next='one ' is not a step name"
  assert_contains "$CHECK" 'duplicate step number 1'
  assert_contains "$CHECK" '2 is missing'
  assert_contains "$CHECK" 'steps/3_three/step.swf: on_failure: must be stop or continue'
  assert_contains "$CHECK" 'steps/3_three/step.swf: opt.export: reserved sbatch option: export'
  assert_contains "$CHECK" 'steps/5_five: missing instructions.sh'
  assert_contains "$CHECK" 'duplicate key: next'
  assert_contains "$CHECK" 'steps/x_bad: name is not <N>_<name>'
  assert_contains "$CHECK" 'steps/07_zero: name is not <N>_<name>'
  STEPS="$(must_capture "$WF/swf" steps)"
  assert_contains "$STEPS" 'invalid x_bad:'
  assert_contains "$STEPS" 'invalid 5_five: missing instructions.sh'
  assert_contains "$STEPS" '3 three -'
  if "$WF/swf" start > /dev/null 2> "$CASE/start.err"; then fail 'start accepted a broken workflow'; fi
  assert_grep 'not starting' "$CASE/start.err"
  assert_grep "next='nope' is not a step name" "$CASE/start.err"
  assert_no_file "$WF/swf.d/run/current.swf"
  assert_eq 0 "$(find "$WF/swf.d/run" -mindepth 1 -maxdepth 1 | wc -l)" 'no run created'
  [[ ! -d "$FAKE_SLURM_DIR/jobs" ]] || assert_eq 0 "$(ls "$FAKE_SLURM_DIR/jobs" | wc -l)" 'nothing submitted'

  case_init check-files
  new_workflow wf
  write_step 1 one
  rm "$WF/swf.d/sbatch_rules.swf"
  printf 'not a header\n' > "$WF/swf.d/workflow.swf"
  if "$WF/swf" check > /dev/null 2> "$CASE/check.err"; then fail 'swf check passed missing rules'; fi
  assert_grep 'sbatch_rules.swf: missing' "$CASE/check.err"
  assert_grep 'workflow.swf: line 1 must be #!swf-v1' "$CASE/check.err"
}

function test_stale_lock_timeout {
  case_init stale-lock
  new_workflow wf
  write_step 1 one
  start_workflow
  mkdir "$WF/swf.d/run/$RUN_ID/lock"
  printf 'pid=999999 host=deadnode\n' > "$WF/swf.d/run/$RUN_ID/lock/owner"
  export SWF_LOCK_TIMEOUT=1 FAKE_SLURM_KEEP_ENV=SWF_LOCK_TIMEOUT
  SECONDS=0
  run_scheduler
  (( SECONDS < 15 )) || fail "lock timeout took $SECONDS s"
  assert_grep 'event=error' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'reason=lock_timeout' "$WF/swf.d/run/$RUN_ID/history"
  assert_grep 'a job may have been killed while holding it' "$WF/log/$RUN_ID/controller.out"
  assert_grep 'pid=999999 host=deadnode' "$WF/log/$RUN_ID/controller.out"
  assert_eq 0 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'nothing submitted'
  # A message command gives the same advice.
  if "$WF/swf" next one > /dev/null 2> "$CASE/next.err"; then fail 'next took a stale lock'; fi
  assert_grep 'if no job of this run is running, remove it' "$CASE/next.err"
}

function test_failed_first_sbatch {
  case_init failed-first-sbatch
  new_workflow wf
  write_step 1 one
  if FAKE_SLURM_SBATCH_FAIL=1 "$WF/swf" start > /dev/null 2> "$CASE/start.err"; then fail 'start succeeded without a controller'; fi
  assert_grep 'no run was started' "$CASE/start.err"
  assert_grep 'Invalid partition name' "$CASE/start.err"
  assert_no_file "$WF/swf.d/run/current.swf"
  assert_eq 0 "$(find "$WF/swf.d/run" -mindepth 1 -maxdepth 1 | wc -l)" 'no run directory'
  assert_eq 0 "$(find "$WF/log" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" 'no log directory'
  # With a previous run, its current.swf is left untouched.
  start_workflow
  run_scheduler
  BEFORE="$(< "$WF/swf.d/run/current.swf")"
  if FAKE_SLURM_SBATCH_FAIL=1 "$WF/swf" start > /dev/null 2>&1; then fail 'second start succeeded'; fi
  assert_eq "$BEFORE" "$(< "$WF/swf.d/run/current.swf")" 'previous current.swf untouched'
  assert_eq 1 "$(find "$WF/swf.d/run" -mindepth 1 -maxdepth 1 -type d | wc -l)" 'only the previous run'
}

function test_start_lock {
  case_init start-lock
  new_workflow wf
  write_step 1 one
  mkdir -p "$WF/swf.d/run/.start.lock"
  if "$WF/swf" start > /dev/null 2> "$CASE/start.err"; then fail 'start ignored the start lock'; fi
  assert_grep 'another swf start is running' "$CASE/start.err"
  [[ -d "$WF/swf.d/run/.start.lock" ]] || fail 'the other start lock was removed'
  rmdir "$WF/swf.d/run/.start.lock"
  start_workflow
  [[ ! -e "$WF/swf.d/run/.start.lock" ]] || fail 'start lock left behind'
  # Two concurrent starts: exactly one wins.
  must "$WF/swf" stop
  local status_a=0 status_b=0
  "$WF/swf" start > "$CASE/a.out" 2> "$CASE/a.err" &
  local pid_a=$!
  "$WF/swf" start > "$CASE/b.out" 2> "$CASE/b.err" &
  local pid_b=$!
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?
  WINNERS="$(cat "$CASE/a.out" "$CASE/b.out" | grep -c . || true)"
  if [[ "$WINNERS" != 1 || "$status_a$status_b" != @(01|10) ]]; then
    printf '    start a: status=%s out=<%s> err=<%s>\n' "$status_a" "$(< "$CASE/a.out")" "$(< "$CASE/a.err")" >&2
    printf '    start b: status=%s out=<%s> err=<%s>\n' "$status_b" "$(< "$CASE/b.out")" "$(< "$CASE/b.err")" >&2
    printf '    runs: %s\n' "$(ls "$WF/swf.d/run" | tr '\n' ' ')" >&2
    fail "concurrent starts: expected one winner, got $WINNERS (statuses $status_a $status_b)"
  fi
}

function test_crlf_scope {
  case_init crlf
  new_workflow wf
  write_step 1 one
  printf 'id,value\r\n1,alpha\r\n' > "$WF/data.csv"
  printf 'x\r\ny\r\n' > "$WF/swf.d/steps/1_one/data.txt"
  printf '#!swf-v1\r\nopt.comment=crlf\r\n' > "$WF/swf.d/steps/1_one/step.swf"
  printf 'printf "ok\\n" >> "$SWF_ROOT/runs"\r\n' > "$WF/swf.d/steps/1_one/instructions.sh"
  CSV_BEFORE="$(md5sum < "$WF/data.csv")"
  TXT_BEFORE="$(md5sum < "$WF/swf.d/steps/1_one/data.txt")"
  start_workflow
  assert_eq "$CSV_BEFORE" "$(md5sum < "$WF/data.csv")" 'user data untouched'
  assert_eq "$TXT_BEFORE" "$(md5sum < "$WF/swf.d/steps/1_one/data.txt")" 'step data untouched'
  if grep -q $'\r' "$WF/swf.d/steps/1_one/step.swf"; then fail 'step.swf still has CRLF'; fi
  if grep -q $'\r' "$WF/swf.d/steps/1_one/instructions.sh"; then fail 'instructions.sh still has CRLF'; fi
  run_scheduler
  assert_grep 'ok' "$WF/runs"
}

function test_stop_reports_scancel_failure {
  case_init scancel-failure
  new_workflow wf
  write_step 1 one
  start_workflow
  if FAKE_SLURM_SCANCEL_FAIL=1 "$WF/swf" stop 2> "$CASE/stop.err"; then fail 'stop hid a scancel failure'; fi
  assert_grep 'scancel failed for controllers' "$CASE/stop.err"
  assert_grep 'Unable to contact slurm controller' "$CASE/stop.err"
  assert_grep 'may still run' "$CASE/stop.err"
  assert_grep 'stopped=' "$WF/swf.d/run/current.swf"
  assert_grep 'cancel_failed=' "$WF/swf.d/run/$RUN_ID/history"
  # The controller still sees the stop and submits nothing.
  run_scheduler
  assert_eq 0 "$(grep -c ' event=submit ' "$WF/swf.d/run/$RUN_ID/history")" 'nothing submitted after stop'
}

function test_start_restores_executable_bit {
  case_init exec-bit
  new_workflow wf
  write_step 1 one
  chmod -x "$WF/swf"
  [[ ! -x "$WF/swf" ]] || fail 'could not remove the executable bit'
  RUN_ID="$(bash "$WF/swf" start 2> "$CASE/start.err")" || fail 'bash swf start failed without the executable bit'
  [[ -x "$WF/swf" ]] || fail 'swf start did not restore the executable bit'
  must "$WF/swf" stop
}

function test_old_bash_is_refused_clearly {
  case_init old-bash
  new_workflow wf
  write_step 1 one
  # BASH_VERSINFO is read-only: force the guard's condition instead.
  local script
  for script in swf swf.d/job.sh swf.d/controller.sh swf.d/lib.sh; do
    sed 's/^if (( BASH_VERSINFO\[0\] < 4 ||/if (( 1 ||/' "$WF/$script" > "$CASE/old-guard.sh"
    assert_grep 'if (( 1 ||' "$CASE/old-guard.sh"
    if bash "$CASE/old-guard.sh" check > "$CASE/old.out" 2> "$CASE/old.err"; then
      fail "$script ran on an old bash"
    else
      assert_eq 2 "$?" "$script exit status"
    fi
    assert_grep 'swf: bash >= 4.2 is required (found ' "$CASE/old.err"
    assert_eq 0 "$(wc -c < "$CASE/old.out")" "$script wrote nothing to stdout"
  done
  # The guard is the first command of every script, after the #SBATCH block.
  local first
  for script in swf.d/job.sh swf.d/controller.sh; do
    first="$(grep -v -e '^#' -e '^$' "$WF/$script" | head -n 1)"
    assert_contains "$first" 'BASH_VERSINFO'
  done
}

function test_first_controller_waits_for_start {
  case_init first-controller-window
  new_workflow wf
  write_step 1 one
  RUN_ID=20990101-000000-1
  RUN_DIR="$WF/swf.d/run/$RUN_ID"
  mkdir -p "$RUN_DIR/msg/override" "$RUN_DIR/used" "$RUN_DIR/failed" "$WF/log/$RUN_ID"
  : > "$RUN_DIR/history"
  # The first controller starts before swf start has written current.swf.
  SLURM_JOB_ID=500 bash "$WF/swf.d/controller.sh" "$WF" "$RUN_ID" first 1_one > "$CASE/ctrl.out" 2>&1 &
  CTRL_PID=$!
  sleep 1.5
  printf '#!swf-v1\nid=%s\nstarted=now\nfirst_step=one\nworkdir=%s\n' "$RUN_ID" "$CASE" > "$WF/swf.d/run/current.swf"
  printf 'time=now event=start first=1_one ctrl=500\n' >> "$RUN_DIR/history"
  wait "$CTRL_PID" || fail "controller failed: $(< "$CASE/ctrl.out")"
  assert_grep 'event=submit step=1_one' "$RUN_DIR/history"
}

# TEST_ONLY=<regex> runs only the tests whose name matches (for debugging).
function run_test {
  local name="$1" function_name="$2"
  if [[ -n "${TEST_ONLY:-}" && ! "$name" =~ $TEST_ONLY ]]; then
    return 0
  fi
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
run_test 'failed step stops the run; messages stay pending; status error line' test_failed_step_stops
run_test 'on_failure=continue (step.swf and override) keeps going' test_on_failure_continue
run_test 'live start refusal, stop, cancellation, and --force' test_stop_and_force
run_test 'log -s/-t selects last job; pending messages in status' test_log_status
run_test 'log --element/--back/--all across map slices and submissions' test_log_selection
run_test 'repeat takes precedence over pending next' test_repeat_precedence
run_test 'cyclic skip stops at loop bound' test_skip_loop_bound
run_test 'first-step override and numeric/name selectors' test_first_step_override_and_selectors
run_test 'override from/reset and .swf validation' test_from_reset_and_parser
run_test 'TERM-killed payload writes marker 143 and stops the run' test_term_kill_marker
run_test 'payload time line: exit code, elapsed, user, system' test_payload_time
run_test 'pre-flight failures write a marker' test_preflight_marker
run_test 'controller after mode takes the finished job id' test_controller_arguments
run_test 'squeue failure keeps the run live; status survives it' test_squeue_failure
run_test 'self-override keeps a pending continuation slice' test_self_override_keeps_continuation
run_test 'invalid option at run time stops with invalid_option' test_invalid_option_at_runtime
run_test 'sbatch_failed and step_not_found carry detail' test_sbatch_failure_detail
run_test 'next/override refused on stopped or missing runs' test_messages_stopped_run
run_test 'numeric references accepted with a note' test_numeric_references
run_test 'swf next records event=replace' test_next_replace_event
run_test 'swf check lists problems; swf start refuses' test_check_and_start_refusal
run_test 'stale lock: controller lock_timeout' test_stale_lock_timeout
run_test 'failed first sbatch leaves no run' test_failed_first_sbatch
run_test 'start lock refuses a concurrent start' test_start_lock
run_test 'CRLF fix leaves user files alone' test_crlf_scope
run_test 'swf stop reports scancel failures' test_stop_reports_scancel_failure
run_test 'purged job ids count as not queued' test_squeue_purged_ids
run_test 'first controller waits for swf start to write current.swf' test_first_controller_waits_for_start
run_test 'swf start restores its executable bit' test_start_restores_executable_bit
run_test 'bash older than 4.2 is refused with a clear message' test_old_bash_is_refused_clearly

printf '\nTest summary\n'
printf '  Total:  %s\n  Passed: %s\n  Failed: %s\n' "$TOTAL" "$PASSED" "$FAILED"
printf '  Scratch: %s%s\n' "$TEST_TMP" "${BASH_COMPAT:+ (BASH_COMPAT=$BASH_COMPAT)}"
if (( FAILED > 0 )); then
  printf '  Result: FAIL (scratch retained)\n'
  exit 1
fi
rm -rf "$TEST_TMP"
printf '  Result: PASS\n'
