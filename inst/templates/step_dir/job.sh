#!/bin/bash

# Mandatory Options
#SBATCH --export=ALL
#SBATCH --open-mode=append

###SBATCH_OPTIONS###

# see https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
set -e

source "$SWF__STEP_SCRIPT"
