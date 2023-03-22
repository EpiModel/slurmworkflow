#!/bin/bash

# Mandatory Options
#SBATCH --export=NONE
#SBATCH --open-mode=append

###SBATCH_OPTIONS###

# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

SWF_ROOT="$1"
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"
make_env_cur_vars "$SWF_CUR"

source "$SWF__STEP_SCRIPT"
