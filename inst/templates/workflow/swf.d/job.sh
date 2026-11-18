#!/bin/bash
#SBATCH --export=NONE
#SBATCH --open-mode=append

if (( $# != 4 )); then
  printf 'usage: job.sh <root> <run_id> <N>_<name> <submission>\n' >&2
  exit 2
fi

SWF_ROOT="$(realpath "$1")"
SWF_RUN_ID="$2"
SWF_STEP_ID="$3"
SWF_SUBMISSION="$(realpath "$4")" || exit 1

source "$SWF_ROOT/swf.d/lib.sh" || exit 1
if ! swf_resolve_step "$SWF_ROOT" "$SWF_STEP_ID" id; then
  swf_error "unknown step: $SWF_STEP_ID"
  exit 1
fi

export SWF_ROOT
export SWF__DIR="$SWF_ROOT/swf.d"
export SWF_NAME="$(basename "$SWF_ROOT")"
export SWF_RUN_ID
export SWF_RUN_DIR="$SWF_ROOT/swf.d/run/$SWF_RUN_ID"
export SWF_LOG_DIR="$SWF_ROOT/log/$SWF_RUN_ID"
export SWF_CMD="$SWF_ROOT/swf"
export SWF_CUR="$STEP_N"
export SWF_CUR_NAME="$STEP_NAME"
export SWF__CUR_DIR="$STEP_DIR"
export SWF__INSTRUCTIONS_SCRIPT="$STEP_DIR/instructions.sh"
export SWF_SUBMISSION

if [[ ! -f "$SWF__INSTRUCTIONS_SCRIPT" ]]; then
  swf_error "instructions not found: $SWF__INSTRUCTIONS_SCRIPT"
  exit 1
fi
if [[ ! -d "$SWF_RUN_DIR" ]]; then
  swf_error "run directory not found: $SWF_RUN_DIR"
  exit 1
fi

bash -e "$SWF__INSTRUCTIONS_SCRIPT"
STATUS=$?
if (( STATUS != 0 )); then
  if [[ -n "${SLURM_ARRAY_JOB_ID:-}" && -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    FAILED_ID="${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
  else
    FAILED_ID="${SLURM_JOB_ID:-unknown}"
  fi
  FAILED_FILE="$SWF_RUN_DIR/failed/$FAILED_ID"
  FAILED_TMP="$SWF_RUN_DIR/failed/.${FAILED_ID}.tmp.$$"
  printf '%s\n' "$STATUS" > "$FAILED_TMP" || exit "$STATUS"
  mv "$FAILED_TMP" "$FAILED_FILE" || exit "$STATUS"
fi
exit "$STATUS"
