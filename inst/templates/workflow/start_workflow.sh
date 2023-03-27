#!/bin/bash

# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

# Throw an informative error if the script is sourced instead of executed
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0
if [[ "$SOURCED" == "1" ]]
then
    echo "This file must be executed and not sourced." 1>&2
    echo 'Replace `source <path to file>`' 1>&2
    echo 'with    `./<path to file>`' 1>&2
    echo "Exiting" 1>&2
    return 0
fi

# Get the absolute path of the workflow directory
SWF_ROOT="$(dirname $0)"
SWF_ROOT="$(realpath $SWF_ROOT)"

USAGE_MSG="$(basename $0) [-h] [-s n] [-d path] -- Script to start a workflow created by `slurmworkflow`

where:
    -h  show this help text
    -s  set the first step to be run (default: 1)
    -d  changes the working directory for the workflow (default: the calling working directory)
"

#### Parse args
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -s)
      FIRST_STEP="$2"
      shift # past argument
      shift # past value
      ;;
    -d)
      cd "$2"
      shift # past argument
      shift # past value
      ;;
    -h)
      echo "$USAGE_MSG"
      exit 0
      ;;
    -*)
      echo "Unknown option $1"
      echo "$USAGE_MSG"
      exit 1
      ;;
  esac
done
####

# without argument the job submits the first step
FIRST_STEP=${FIRST_STEP:-1}

# source the common bash functions
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"

# Create the log folder if it does not exist
if [[ ! -d "$SWF_LOG_DIR" ]]
then
  mkdir -p "$SWF_LOG_DIR"
fi

# Convert Windows CRLF endings to LF
fix_crlf_files "$SWF_ROOT"

# Submit the controller with 2 arguments: the root folder and next step
sbatch  --output="$SWF__CTRL_OUT" \
        --job-name="$SWF__CTRL_NAME" \
        "$SWF__CTRL_SCRIPT" \
        "$SWF_ROOT" \
        "$FIRST_STEP"
