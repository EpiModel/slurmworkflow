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

# without argument the job submits the first step
export SWF_CUR=${1:-1}
SWF__NEXTSTEP_OPTS="$2"
export SWF__CUR_DIR="$SWF__STEPS_DIR/$SWF_CUR"

SWF__JOB_SCRIPT="$SWF__CUR_DIR/job.sh"
export SWF__INSTRUCTIONS_SCRIPT="$SWF__CUR_DIR/instructions.sh"

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

