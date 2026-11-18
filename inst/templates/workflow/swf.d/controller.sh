#!/bin/bash
#SBATCH --open-mode=append
#SBATCH --time=10
#SBATCH --nodes=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500
#SBATCH --export=NONE

set -e

if (( $# != 4 )) && ! { (( $# == 5 )) && [[ "$3" == after ]]; }; then
  printf 'usage: controller.sh <root> <run_id> first <N>_<name> | <root> <run_id> after <N>_<name> <submission>\n' >&2
  exit 2
fi

SWF_ROOT="$1"
SWF_RUN_ID="$2"
SWF_MODE="$3"
SWF_FINISHED_ID="$4"
SWF_FINISHED_FILE="${5:-}"
SWF_CTRL_ID="${SLURM_JOB_ID:-$$}"
SWF_RUN_DIR="$SWF_ROOT/swf.d/run/$SWF_RUN_ID"
SWF_CURRENT="$SWF_ROOT/swf.d/run/current.swf"
SWF_NAME="$(basename "$SWF_ROOT")"
SWF_LOG_DIR="$SWF_ROOT/log/$SWF_RUN_ID"
SWF_SOURCE_PATH=''

export SWF__DIR="$SWF_ROOT/swf.d"
source "$SWF_ROOT/swf.d/lib.sh"
trap swf_unlock EXIT

function controller_error {
  local reason="$1"
  swf_history "$SWF_RUN_DIR" error "by=$SWF_CTRL_ID" "reason=$reason"
  printf 'Controller error: %s\n' "$reason" >&2
  swf_unlock
  exit 1
}

function print_command {
  local label="$1"
  shift
  printf '%s' "$label"
  printf ' %q' "$@"
  printf '\n'
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
      controller_error step_not_found
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

TARGET_ID=''
HAVE_TARGET_FILE=0
TARGET_FILE=''

if [[ "$SWF_MODE" == first ]]; then
  TARGET_ID="$SWF_FINISHED_ID"
elif [[ "$SWF_MODE" == after ]]; then
  if ! swf_resolve_step "$SWF_ROOT" "$SWF_FINISHED_ID" id; then
    controller_error step_not_found
  fi
  FINISHED_NAME="$STEP_NAME"
  FINISHED_NUMBER="$STEP_N"
  FILE_PATH="$SWF_FINISHED_FILE"

  swf_lock "$SWF_RUN_DIR" || exit 1

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
          controller_error step_not_found
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
    controller_error step_not_found
  fi
  TARGET_ID="$STEP_ID"
  TARGET_NUMBER="$STEP_N"
  TARGET_NAME="$STEP_NAME"

  if (( HAVE_TARGET_FILE )); then
    :
  else
    if [[ "$SWF_LOCK_HELD" != 1 ]]; then
      swf_lock "$SWF_RUN_DIR" || exit 1
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
if ! JOB_ID="$("${STEP_COMMAND[@]}")"; then
  controller_error sbatch_failed
fi
JOB_ID="${JOB_ID%%;*}"
if [[ ! "$JOB_ID" =~ ^[0-9]+$ ]]; then
  controller_error sbatch_failed
fi
printf 'Submitted %s as job %s from %s.\n' "$TARGET_ID" "$JOB_ID" "$TARGET_FILE"

swf_read "$SWF_ROOT/swf.d/workflow.swf" || controller_error invalid_workflow
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
  after "$TARGET_ID" "$TARGET_FILE")
print_command 'Controller sbatch:' "${CTRL_COMMAND[@]}"
if ! NEXT_CTRL_ID="$("${CTRL_COMMAND[@]}")"; then
  controller_error sbatch_failed
fi
NEXT_CTRL_ID="${NEXT_CTRL_ID%%;*}"
if [[ ! "$NEXT_CTRL_ID" =~ ^[0-9]+$ ]]; then
  controller_error sbatch_failed
fi

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
