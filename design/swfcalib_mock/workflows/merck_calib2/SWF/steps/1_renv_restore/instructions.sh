. /projects/epimodel/spack/share/spack/setup-env.sh
spack load r@4.6.1
spack load rust@1.97.1
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CUR_BRANCH" != "main" ]]; then
echo 'The git branch is not `main`.)
Exiting' 1>&2
exit 1
fi
git pull
Rscript -e "renv::init(bare = TRUE, load = FALSE)"
Rscript -e "renv::restore(lockfile = 'renv.lock.hpc')"
