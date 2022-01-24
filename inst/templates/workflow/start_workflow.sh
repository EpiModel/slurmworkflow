#!/bin/bash

# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

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

sbatch  --output="$SWF__CTRL_OUT" \
        --job-name="$SWF__CTRL_NAME" \
        "$SWF__CTRL_SCRIPT" "$FIRST_STEP"
