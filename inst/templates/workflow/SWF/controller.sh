#!/bin/bash

# Mandatory Options
#SBATCH --open-mode=append
#SBATCH --time=10
#SBATCH --nodes=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500
#SBATCH --export=ALL

###SBATCH_OPTIONS###


# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

# TODO: pass SWF_ROOT as first arg and build vars from lib.sh
SWF_ROOT="$1"
SWF_CUR="$2"     # number of the current step
SWF__NEXTSTEP_OPTS="$3" # optional args to SBATCH

# source the common bash functions
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"
make_env_cur_vars "$SWF_CUR"

if [[ -f "$SWF__JOB_SCRIPT" ]]
then
    sbatch --dependency=afterany:"$SLURM_JOB_ID" \
           --output="$SWF__STEPS_OUT" \
           --job-name="${SWF_NAME}_step${SWF_CUR}" \
           ${SWF__NEXTSTEP_OPTS} \
           "$SWF__JOB_SCRIPT"

    echo "Step number $SWF_CUR has been submitted"
else
    echo "All steps are done"
fi

