# Ensure the existence of the required variables
export SWF_CUR_TMP=${SLURM_TMPDIR:-${TMP:-"/tmp"}}
SWF__JOB_ID=${SLURM_JOB_ID:-$SLURM_ARRAY_JOB_ID}

# SWF_NEXTSTEP_FILE is where the job can require a specific step to be run after
# this one.
# The variable is exported so it is accessible by the instructions run
# afterwards
export SWF_NEXTSTEP_FILE="$SWF_CUR_TMP/$SWF__JOB_ID.nextstep"
export SWF_NEXTSTEP_OPTS_FILE="$SWF_CUR_TMP/$SWF__JOB_ID.nextstep_opts"

# This file contains only boilerplate code for the workflow system. The
# instructions to be run for the job are in an external script. The script is
# sourced and not executed so it shares the same shell.
source "$SWF__INSTRUCTIONS_SCRIPT"

# The "controller" script is run in between each step.
# It decides wether or not there are still steps to be run.
# In an array of jobs, the last task in the array is the one submitting the
# "controller" script again
if [[ -z $SLURM_ARRAY_TASK_ID || $SLURM_ARRAY_TASK_ID = $SLURM_ARRAY_TASK_MAX ]]
then
    # check if the file `SWF_NEXTSTEP_FILE` exits. If so, get the value it
    # contains and remove it.
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

        if [[ -f "$SWF_NEXTSTEP_OPTS_FILE" ]]
        then
            SWF__NEXTSTEP_OPTS=$(cat "$SWF_NEXTSTEP_OPTS_FILE")
        else
            SWF__NEXTSTEP_OPTS=""
        fi
    else
        SWF__NEXTSTEP=$(($SWF_CUR + 1))
    fi

    # Unset variables specific to this job before submitting the next
    export SWF_CUR=
    export SWF_CUR_TMP=
    export SWF_NEXTSTEP_FILE=

    export SWF__CUR_DIR=
    export SWF__INSTRUCTIONS_SCRIPT=

    # Submit the controller again
    sbatch --dependency=afterany:"$SWF__JOB_ID" \
           --output="$SWF__CTRL_OUT" \
           --job-name="$SWF__CTRL_NAME" \
           "$SWF__CTRL_SCRIPT" "$SWF__NEXTSTEP" "$SWF__NEXTSTEP_OPTS"
fi
