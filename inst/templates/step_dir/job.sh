#!/bin/bash

# Mandatory Options
#SBATCH --export=NONE
#SBATCH --open-mode=append

###SBATCH_OPTIONS###

# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

SWF_ROOT="$1"
SWF_CUR="$2"
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"
make_env_cur_vars "$SWF_CUR"

# Parent-shell setup hook. The payload runs in a child shell and cannot modify
# the environment that submits the controller. Load modules, set PATH, or run
# other site-specific setup needed by `sbatch` here.
if [[ -f "$SWF_ROOT/SWF/parent_setup.sh" ]]
then
    source "$SWF_ROOT/SWF/parent_setup.sh"
fi

source "$SWF__STEP_SCRIPT"
