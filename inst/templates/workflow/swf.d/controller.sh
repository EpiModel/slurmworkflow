#!/bin/bash
#SBATCH --open-mode=append
#SBATCH --time=10
#SBATCH --nodes=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500
#SBATCH --export=NONE

# Refuse old bash first, with syntax that bash 3.2 (stock macOS) can parse.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  printf 'swf: bash >= 4.2 is required (found %s)\n' "${BASH_VERSION%%[!0-9.]*}" >&2
  exit 2
fi

set -e

function controller_usage {
  printf 'usage: controller.sh <root> <run_id> first <N>_<name>\n' >&2
  printf '       controller.sh <root> <run_id> after <N>_<name> <submission> <job_id>\n' >&2
  exit 2
}

if (( $# == 4 )) && [[ "$3" == first ]]; then
  :
elif (( $# == 6 )) && [[ "$3" == after && "$6" =~ ^[0-9]+$ ]]; then
  :
else
  controller_usage
fi

SWF_ROOT="$1"
SWF_RUN_ID="$2"
SWF_MODE="$3"
SWF_FINISHED_ID="$4"
SWF_FINISHED_FILE="${5:-}"
SWF_FINISHED_JOB="${6:-}"
SWF_CTRL_ID="${SLURM_JOB_ID:-$$}"
SWF_RUN_DIR="$SWF_ROOT/swf.d/run/$SWF_RUN_ID"
SWF_CURRENT="$SWF_ROOT/swf.d/run/current.swf"
SWF_NAME="$(basename "$SWF_ROOT")"
SWF_LOG_DIR="$SWF_ROOT/log/$SWF_RUN_ID"
SWF_SOURCE_PATH=''

export SWF__DIR="$SWF_ROOT/swf.d"
source "$SWF_ROOT/swf.d/lib.sh"
trap swf_unlock EXIT

# Append event=error with a reason (and optional extra key=value fields) to
# the history, print it, release the lock and exit 1. Exiting non-zero lets
# ctrl.opt.mail-type=FAIL tell the user.
function controller_error {
  local reason="$1"
  shift
  swf_history "$SWF_RUN_DIR" error "by=$SWF_CTRL_ID" "reason=$reason" "$@"
  printf 'Controller error: %s' "$reason" >&2
  (( $# == 0 )) || printf ' %s' "$@" >&2
  printf '\n' >&2
  swf_unlock
  exit 1
}

function controller_lock {
  swf_lock "$SWF_RUN_DIR" || controller_error lock_timeout
}

function not_found {
  printf 'Step not found: %q\n' "$1" >&2
  controller_error "step_not_found:$(swf_history_value "$1")"
}

function print_command {
  local label="$1"
  shift
  printf '%s' "$label"
  printf ' %q' "$@"
  printf '\n'
}

# Run an sbatch command; set SBATCH_ID to the parsed job id. sbatch's stderr
# is captured and printed in the controller log.
function submit {
  local err_file status=0 err
  err_file="$SWF_RUN_DIR/.sbatch.err.$$"
  SBATCH_ID="$("$@" 2> "$err_file")" || status=$?
  err=''
  [[ -f "$err_file" ]] && err="$(< "$err_file")"
  rm -f "$err_file"
  if [[ -n "$err" ]]; then
    printf 'sbatch stderr:\n%s\n' "$err"
  fi
  if (( status != 0 )); then
    printf 'sbatch exited with status %s.\n' "$status"
    return 1
  fi
  SBATCH_ID="${SBATCH_ID%%;*}"
  if [[ ! "$SBATCH_ID" =~ ^[0-9]+$ ]]; then
    printf 'sbatch returned an invalid job id: %s\n' "$SBATCH_ID"
    return 1
  fi
}

function select_following_step {
  # Uses FILE_NUMBER, FILE_NAME and FILE_PATH. Sets TARGET_ID to a step id,
  # or to an empty string for end-of-workflow.
  local next_present=0
  local next_name=''
  local next_number

  swf_read "$FILE_PATH" || controller_error invalid_submission
  if [[ ${SWF_VALUES[next]+present} ]]; then
    next_present=1
    next_name="${SWF_VALUES[next]}"
  fi

  if (( next_present )); then
    if [[ -z "$next_name" ]]; then
      TARGET_ID=''
      return 0
    fi
    if ! swf_resolve_step "$SWF_ROOT" "$next_name"; then
      not_found "$next_name"
    fi
    TARGET_ID="$STEP_ID"
    return 0
  fi

  next_number=$((10#$FILE_NUMBER + 1))
  if swf_resolve_step "$SWF_ROOT" "$next_number" number; then
    TARGET_ID="$STEP_ID"
  else
    TARGET_ID=''
  fi
}

# Validate the engine keys of the file last read (A8).
function validate_submission {
  local path="$1" problem
  if ! swf_validate_keys; then
    for problem in "${SWF_KEY_PROBLEMS[@]}"; do
      printf 'Invalid key in %s: %s\n' "$path" "$problem" >&2
    done
    controller_error "invalid_option:$(swf_history_value "$SWF_INVALID_KEY")"
  fi
}

# swf start writes current.swf (then event=start) right after sbatch accepts
# the first controller. If this controller starts in that window, wait for it
# (at most 60 s; a failed start removes the run directory).
function current_run_id {
  CURRENT_ID=''
  if [[ -f "$SWF_CURRENT" ]]; then
    swf_read "$SWF_CURRENT" || exit 1
    CURRENT_ID="${SWF_VALUES[id]:-}"
  fi
}
current_run_id
if [[ "$SWF_MODE" == first && "$CURRENT_ID" != "$SWF_RUN_ID" ]]; then
  for (( WAIT = 0; WAIT < 60; WAIT++ )); do
    [[ -d "$SWF_RUN_DIR" ]] || break
    if [[ -f "$SWF_RUN_DIR/history" ]] && grep -q ' event=start ' "$SWF_RUN_DIR/history"; then break; fi
    sleep 1
    current_run_id
    [[ "$CURRENT_ID" != "$SWF_RUN_ID" ]] || break
  done
fi
if [[ ! -f "$SWF_CURRENT" ]]; then
  printf 'No current run; controller %s exits.\n' "$SWF_CTRL_ID"
  exit 0
fi
swf_read "$SWF_CURRENT" || exit 1
if [[ "${SWF_VALUES[id]:-}" != "$SWF_RUN_ID" || ${SWF_VALUES[stopped]+present} ]]; then
  printf 'Run %s is no longer active; controller %s exits.\n' "$SWF_RUN_ID" "$SWF_CTRL_ID"
  exit 0
fi

if [[ ! -d "$SWF_RUN_DIR" ]]; then
  printf 'Run directory not found: %s\n' "$SWF_RUN_DIR" >&2
  exit 1
fi

if ! swf_load_rules "$SWF_ROOT"; then
  controller_error invalid_rules
fi

TARGET_ID=''
HAVE_TARGET_FILE=0
TARGET_FILE=''

if [[ "$SWF_MODE" == first ]]; then
  TARGET_ID="$SWF_FINISHED_ID"
elif [[ "$SWF_MODE" == after ]]; then
  if ! swf_resolve_step "$SWF_ROOT" "$SWF_FINISHED_ID" id; then
    not_found "$SWF_FINISHED_ID"
  fi
  FINISHED_NAME="$STEP_NAME"
  FINISHED_NUMBER="$STEP_N"
  FILE_PATH="$SWF_FINISHED_FILE"

  # A failed step stops the run unless its submission says on_failure=continue.
  # Check before claiming anything: pending messages stay pending.
  FAILED_MARKERS=()
  for MARKER in "$SWF_RUN_DIR/failed/$SWF_FINISHED_JOB" "$SWF_RUN_DIR/failed/${SWF_FINISHED_JOB}_"*; do
    if [[ -f "$MARKER" ]]; then FAILED_MARKERS+=("$MARKER"); fi
  done
  if (( ${#FAILED_MARKERS[@]} > 0 )); then
    swf_read "$SWF_FINISHED_FILE" || controller_error invalid_submission
    ON_FAILURE="${SWF_VALUES[on_failure]:-stop}"
    if [[ "$ON_FAILURE" != stop && "$ON_FAILURE" != continue ]]; then
      printf 'Invalid key in %s: on_failure: must be stop or continue\n' "$SWF_FINISHED_FILE" >&2
      controller_error invalid_option:on_failure
    fi
    printf 'Job %s of %s failed (%s marker(s)):\n' "$SWF_FINISHED_JOB" "$SWF_FINISHED_ID" "${#FAILED_MARKERS[@]}"
    for MARKER in "${FAILED_MARKERS[@]}"; do
      printf '  failed/%s exit=%s\n' "${MARKER##*/}" "$(head -n 1 "$MARKER" 2>/dev/null || true)"
    done
    if [[ "$ON_FAILURE" == continue ]]; then
      printf 'on_failure=continue: the workflow goes on.\n'
    else
      controller_error "step_failed:$SWF_FINISHED_ID" "failed=${#FAILED_MARKERS[@]}"
    fi
  fi

  controller_lock

  # A continuation for S wins over a pending next message. Claim it here so
  # that it cannot also be consumed by another controller.
  REPEAT_FILE="$SWF_RUN_DIR/msg/override/$FINISHED_NAME.swf"
  if [[ -f "$REPEAT_FILE" ]]; then
    swf_read "$REPEAT_FILE" || controller_error invalid_override
    if [[ "${SWF_VALUES[repeat]:-}" == 1 ]]; then
      TARGET_FILE="$SWF_RUN_DIR/used/${SWF_CTRL_ID}_override_${FINISHED_NAME}.swf"
      mv "$REPEAT_FILE" "$TARGET_FILE"
      swf_history "$SWF_RUN_DIR" claim \
        "file=used/${SWF_CTRL_ID}_override_${FINISHED_NAME}.swf" "by=$SWF_CTRL_ID"
      printf 'Claimed repeat override for %s as %s.\n' "$FINISHED_NAME" "$TARGET_FILE"
      TARGET_ID="${FINISHED_NUMBER}_${FINISHED_NAME}"
      HAVE_TARGET_FILE=1
    fi
  fi

  if (( ! HAVE_TARGET_FILE )); then
    NEXT_FILE="$SWF_RUN_DIR/msg/next.swf"
    if [[ -f "$NEXT_FILE" ]]; then
      USED_NEXT="$SWF_RUN_DIR/used/${SWF_CTRL_ID}_next.swf"
      mv "$NEXT_FILE" "$USED_NEXT"
      swf_history "$SWF_RUN_DIR" claim \
        "file=used/${SWF_CTRL_ID}_next.swf" "by=$SWF_CTRL_ID"
      printf 'Claimed next message as %s.\n' "$USED_NEXT"
      swf_read "$USED_NEXT" || controller_error invalid_next
      if [[ ! ${SWF_VALUES[next]+present} ]]; then
        controller_error invalid_next
      fi
      NEXT_NAME="${SWF_VALUES[next]}"
      if [[ -z "$NEXT_NAME" ]]; then
        TARGET_ID=''
      else
        if ! swf_resolve_step "$SWF_ROOT" "$NEXT_NAME"; then
          not_found "$NEXT_NAME"
        fi
        TARGET_ID="$STEP_ID"
      fi
    else
      FILE_NUMBER="$FINISHED_NUMBER"
      FILE_NAME="$FINISHED_NAME"
      select_following_step
    fi
  fi
else
  controller_error invalid_mode
fi

MAX_SKIPS=$(( $(swf_step_count "$SWF_ROOT") + 1 ))
SKIP_COUNT=0

# Resolve the target, consume its one-shot override, and follow skip messages.
# This loop is intentionally independent of the static graph: skips may cycle.
while :; do
  if [[ -z "$TARGET_ID" ]]; then
    swf_history "$SWF_RUN_DIR" end "by=$SWF_CTRL_ID"
    printf 'No step left; workflow run %s ends.\n' "$SWF_RUN_ID"
    swf_unlock
    exit 0
  fi

  if ! swf_resolve_step "$SWF_ROOT" "$TARGET_ID" id; then
    not_found "$TARGET_ID"
  fi
  TARGET_ID="$STEP_ID"
  TARGET_NUMBER="$STEP_N"
  TARGET_NAME="$STEP_NAME"

  if (( HAVE_TARGET_FILE )); then
    :
  else
    if [[ "$SWF_LOCK_HELD" != 1 ]]; then
      controller_lock
    fi
    OVERRIDE_FILE="$SWF_RUN_DIR/msg/override/$TARGET_NAME.swf"
    if [[ -f "$OVERRIDE_FILE" ]]; then
      TARGET_FILE="$SWF_RUN_DIR/used/${SWF_CTRL_ID}_override_${TARGET_NAME}.swf"
      mv "$OVERRIDE_FILE" "$TARGET_FILE"
      swf_history "$SWF_RUN_DIR" claim \
        "file=used/${SWF_CTRL_ID}_override_${TARGET_NAME}.swf" "by=$SWF_CTRL_ID"
      printf 'Claimed override for %s as %s.\n' "$TARGET_NAME" "$TARGET_FILE"
    else
      TARGET_FILE="$STEP_DIR/step.swf"
    fi
  fi

  swf_read "$TARGET_FILE" || controller_error invalid_submission
  validate_submission "$TARGET_FILE"
  if [[ "${SWF_VALUES[skip]:-}" == 1 ]]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    if (( SKIP_COUNT > MAX_SKIPS )); then
      controller_error skip_loop
    fi
    swf_history "$SWF_RUN_DIR" skip "step=$TARGET_ID" "by=$SWF_CTRL_ID"
    printf 'Skipping %s.\n' "$TARGET_ID"
    FILE_NUMBER="$TARGET_NUMBER"
    FILE_NAME="$TARGET_NAME"
    FILE_PATH="$TARGET_FILE"
    HAVE_TARGET_FILE=0
    TARGET_FILE=''
    select_following_step
    continue
  fi
  break
done

swf_unlock

# Build argument vectors directly from parsed keys. Values are never split.
swf_read "$TARGET_FILE" || controller_error invalid_submission
STEP_ARGS=()
for KEY in "${SWF_KEYS[@]}"; do
  if [[ "$KEY" == opt.* ]]; then
    STEP_ARGS+=("--${KEY#opt.}=${SWF_VALUES[$KEY]}")
  fi
done

STEP_COMMAND=(sbatch --parsable "--job-name=${SWF_NAME}_${TARGET_ID}" \
  "--output=$SWF_LOG_DIR/${TARGET_ID}_%A_%a.out")
STEP_COMMAND+=(${STEP_ARGS[@]+"${STEP_ARGS[@]}"})
STEP_COMMAND+=("$SWF_ROOT/swf.d/job.sh" "$SWF_ROOT" "$SWF_RUN_ID" \
  "$TARGET_ID" "$TARGET_FILE")
print_command 'Step sbatch:' "${STEP_COMMAND[@]}"
if ! submit "${STEP_COMMAND[@]}"; then
  controller_error "sbatch_failed:$TARGET_ID"
fi
JOB_ID="$SBATCH_ID"
printf 'Submitted %s as job %s from %s.\n' "$TARGET_ID" "$JOB_ID" "$TARGET_FILE"

swf_read "$SWF_ROOT/swf.d/workflow.swf" || controller_error invalid_workflow "job=$JOB_ID"
CTRL_ARGS=()
for KEY in "${SWF_KEYS[@]}"; do
  if [[ "$KEY" == ctrl.opt.* ]]; then
    CTRL_ARGS+=("--${KEY#ctrl.opt.}=${SWF_VALUES[$KEY]}")
  fi
done

CTRL_COMMAND=(sbatch --parsable "--dependency=afterany:$JOB_ID" \
  "--job-name=${SWF_NAME}_ctrl" "--output=$SWF_LOG_DIR/controller.out")
CTRL_COMMAND+=(${CTRL_ARGS[@]+"${CTRL_ARGS[@]}"})
CTRL_COMMAND+=("$SWF_ROOT/swf.d/controller.sh" "$SWF_ROOT" "$SWF_RUN_ID" \
  after "$TARGET_ID" "$TARGET_FILE" "$JOB_ID")
print_command 'Controller sbatch:' "${CTRL_COMMAND[@]}"
if ! submit "${CTRL_COMMAND[@]}"; then
  # The step job is queued but nothing will follow it. Keep its id in the
  # history so that swf stop can cancel it.
  printf 'Step job %s is queued but no controller follows it.\n' "$JOB_ID" >&2
  controller_error "sbatch_failed:$TARGET_ID" "job=$JOB_ID" submitting=controller
fi
NEXT_CTRL_ID="$SBATCH_ID"

if [[ "$TARGET_FILE" == "$SWF_ROOT/swf.d/"* ]]; then
  SWF_SOURCE_PATH="${TARGET_FILE#"$SWF_ROOT/swf.d/"}"
else
  SWF_SOURCE_PATH="$TARGET_FILE"
fi
swf_history "$SWF_RUN_DIR" submit "step=$TARGET_ID" "job=$JOB_ID" \
  "ctrl=$NEXT_CTRL_ID" "by=$SWF_CTRL_ID" "from=$SWF_SOURCE_PATH"

# stop() may have run while either submission was in flight. Cancel controllers
# first, then the newly submitted step, as swf stop itself does.
if swf_read "$SWF_CURRENT" && [[ ${SWF_VALUES[stopped]+present} ]]; then
  printf 'Run was stopped during submission; cancelling %s and %s.\n' \
    "$NEXT_CTRL_ID" "$JOB_ID"
  scancel "$NEXT_CTRL_ID" "$JOB_ID" 2>/dev/null || true
fi
