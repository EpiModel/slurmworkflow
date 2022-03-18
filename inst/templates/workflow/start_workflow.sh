#!/bin/bash

# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

# Throw an informative error if the script is sourced instead of executed
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0
if [[ "$SOURCED" == "1" ]]
then
    echo "This file must be executed and not sourced." 1>&2
    echo 'Replace `source <path to file>`' 1>&2
    echo 'with    `<path to file>`' 1>&2
    echo "Exiting" 1>&2
    return 0
fi

# without argument the job submits the first step
FIRST_STEP=${1:-1}

# Environment variables for the user
export SWF_ROOT="$(dirname $0)"
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

# Create the log folder if it does no exist
if [[ ! -d "$SWF_LOG_DIR" ]]
then
  mkdir -p "$SWF_LOG_DIR"
fi

# CRLF to LF - `|| echo ""` prevents error when none is found
CRLF_FILES=$(find "$SWF_ROOT" -type f | xargs file -F "::" | grep CRLF || echo "")
if [[ -n "$CRLF_FILES" ]]
then
  echo "$CRLF_FILES" | sed 's/::.*$//' | xargs perl -pi -e 's/\r\n/\n/g'
fi

sbatch  --output="$SWF__CTRL_OUT" \
        --job-name="$SWF__CTRL_NAME" \
        "$SWF__CTRL_SCRIPT" "$FIRST_STEP"
