# Export a var pointing to the `tmp` folder for the job
export SWF_CUR_TMP=${SLURM_TMPDIR:-${TMP:-"/tmp"}}
# Common job id var
SWF__JOB_ID=${SLURM_JOB_ID:-$SLURM_ARRAY_JOB_ID}

# SWF_NEXTSTEP_FILE is where the job can require a specific step to be run after
# this one.
# The variable is exported so it is accessible by the instructions run
# afterwards
export SWF_NEXTSTEP_FILE="$SWF_CUR_TMP/$SWF__JOB_ID.nextstep"
export SWF_NEXTSTEP_OPTS_FILE="$SWF_CUR_TMP/$SWF__JOB_ID.nextstep_opts"

# The controller is submitted by this shell after the payload. The payload's
# child shell cannot provide `sbatch` to this parent shell, so check it here.
if ! command -v sbatch > /dev/null 2>&1
then
    echo "sbatch not found in the step environment; cannot submit the controller." >&2
    exit 127
fi

# The payload is executed in a child bash, not sourced. It inherits the
# exported SWF_* variables and the process environment, but cannot change this
# shell's cwd, options, PATH, functions, or exit before the hand-off.
# See the "Step payload contract" vignette in the slurmworkflow documentation.
# >>> SWF_PAYLOAD_INVOCATION >>>
set +e
env -u BASH_ENV "${BASH:-/bin/bash}" -e -- "$SWF__INSTRUCTIONS_SCRIPT"
SWF__RC=$?
set -e
if (( SWF__RC != 0 ))
then
    echo "Step payload failed with exit code $SWF__RC: $SWF__INSTRUCTIONS_SCRIPT" >&2
    exit "$SWF__RC"
fi
# <<< SWF_PAYLOAD_INVOCATION <<<

# The "controller" script is run in between each step.
# It decides wether or not there are still steps to be run.
# In an array of jobs, the last task in the array is the one submitting the
# "controller" script again
if [[ -z $SLURM_ARRAY_TASK_ID || $SLURM_ARRAY_TASK_ID = $SLURM_ARRAY_TASK_MAX ]]
then
    # check if the file `SWF_NEXTSTEP_FILE` exits.
    # If so, get the value it contains and delete the file.
    # Otherwise, SWF__NEXTSTEP is SWF_CUR + 1
    if [[ -f "$SWF_NEXTSTEP_FILE" ]]
    then
        SWF__NEXTSTEP=$(cat "$SWF_NEXTSTEP_FILE")
        rm "$SWF_NEXTSTEP_FILE"

        # Check if `SWF_NEXTSTEP` is an integer without leading 0
        # If malformed: exit
        SWF__INTEGER_RE='^[1-9][0-9]*$'
        if ! [[ $SWF__NEXTSTEP =~ $SWF__INTEGER_RE ]]
        then
            echo "The content of 'SWF_NEXTSTEP_FILE' is malformed: $SWF__NEXTSTEP" >&2
            exit 1
        fi

        # Get the additional options for the next steps if any.
        # They are stored in the `SWF_NEXTSTEP_OPTS_FILE` file.
        if [[ -f "$SWF_NEXTSTEP_OPTS_FILE" ]]
        then
            SWF__NEXTSTEP_OPTS=$(cat "$SWF_NEXTSTEP_OPTS_FILE")
        else
            SWF__NEXTSTEP_OPTS=""
        fi
    else
        SWF__NEXTSTEP=$(($SWF_CUR + 1))
    fi

    # Submit the controller again
    sbatch --dependency=afterany:"$SWF__JOB_ID" \
           --output="$SWF__CTRL_OUT" \
           --job-name="$SWF__CTRL_NAME" \
           "$SWF__CTRL_SCRIPT" \
           "$SWF_ROOT" \
           "$SWF__NEXTSTEP" \
           "$SWF__NEXTSTEP_OPTS"
fi
