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

# Archive old log files for a step before resubmitting it.
# Moves .out files with a job ID lower than the current one to log/archive/.
# Arguments:
#   $1 - step name (e.g., "wf_name_step1")
#   $2 - current SLURM job ID (files with lower IDs are considered old)
#   $3 - log directory path
function archive_old_logs {
  local step_name="$1"
  local current_jobid="$2"
  local log_dir="$3"
  local archive_dir="$log_dir/archive"

  for f in "$log_dir"/${step_name}_*.out; do
    [ -f "$f" ] || continue

    local basename
    basename=$(basename "$f")
    # Remove the step_name_ prefix and .out suffix to get JOBID_TASKID
    local remainder="${basename#${step_name}_}"
    remainder="${remainder%.out}"
    # Extract the job ID (part before the first _)
    local file_jobid="${remainder%%_*}"

    if [[ "$file_jobid" =~ ^[0-9]+$ ]] && [ "$file_jobid" -lt "$current_jobid" ]; then
      mkdir -p "$archive_dir"
      mv "$f" "$archive_dir/"
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
