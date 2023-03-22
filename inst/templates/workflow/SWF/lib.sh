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

# convert CRLF endings to LF - `|| echo ""` prevents error when none is found
function fix_crlf_files {
  local CRLF_FILES=$(find "$1" -type f | xargs file -F "::" | grep CRLF || echo "")
  if [[ -n "$CRLF_FILES" ]]
  then
    echo "$CRLF_FILES" | sed 's/::.*$//' | xargs perl -pi -e 's/\r\n/\n/g'
  fi
}
