#!/bin/bash

function make_env_vars {
  export SWF_ROOT="$1"
  export SWF_NAME="$(basename $SWF_ROOT)"
  export SWF_SUMMARY="$SWF_ROOT/workflow.yaml"
  export SWF_LOG_DIR="$SWF_ROOT/log"

  # Environment variables for the workflow itself
  export SWF__DIR="$SWF_ROOT/SWF"
  # Related to the controller script
  export SWF__CTRL_SCRIPT="$SWF__DIR/controller.sh"
  export SWF__CTRL_NAME="${SWF_NAME}_controller"
  export SWF__CTRL_OUT="$SWF_LOG_DIR/%x.out"
  # Related to the steps
  export SWF__STEPS_DIR="$SWF__DIR/steps"
  export SWF__STEP_SCRIPT="$SWF__DIR/step.sh"
  export SWF__STEPS_OUT="$SWF_LOG_DIR/%x_%A_%a.out"
}

function make_env_cur_vars {
  export SWF_CUR="$1"
  export SWF__CUR_DIR="$SWF__STEPS_DIR/$SWF_CUR"
  export SWF__JOB_SCRIPT="$SWF__CUR_DIR/job.sh"
  export SWF__INSTRUCTIONS_SCRIPT="$SWF__CUR_DIR/instructions.sh"
}

# Move the step logs of earlier runs to `log/archive/`, for the steps that are
# about to run again: every step from the first step of this run onward.
# Logs of the earlier steps are kept, as are the logs of a step that runs
# several times within a run (array slices from `step_tmpl_map`, loops with
# `change_next_workflow_step`), since archiving happens only at the start.
# Arguments:
#   $1 - first step of the run
function archive_old_logs {
  local first_step="$1"
  local log_prefix="$SWF_LOG_DIR/${SWF_NAME}_step"
  local log_file
  local step

  for log_file in "$log_prefix"*_*.out
  do
    # the pattern itself is returned when nothing matches
    [[ -f "$log_file" ]] || continue

    # file names are <wf_name>_step<N>_<jobid>_<taskid>.out
    step="${log_file#"$log_prefix"}"
    step="${step%%_*}"
    if [[ "$step" =~ ^[0-9]+$ ]] && (( 10#$step >= 10#$first_step ))
    then
      mkdir -p "$SWF_LOG_DIR/archive"
      mv "$log_file" "$SWF_LOG_DIR/archive/"
    fi
  done
}

# convert CRLF endings to LF - `|| echo ""` prevents error when none is found
function fix_crlf_files {
  local CRLF_FILES=$(find "$1" -type f | xargs file -F "::" | grep CRLF || echo "")
  if [[ -n "$CRLF_FILES" ]]
  then
    echo "$CRLF_FILES" | sed 's/::.*$//' | xargs perl -pi -e 's/\r\n/\n/g'
  fi
}
