% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/workflow.R
\name{add_workflow_step}
\alias{add_workflow_step}
\title{Add a Step to an Existing Workflow}
\usage{
add_workflow_step(wf_summary, step_tmpl, sbatch_opts = NULL, step_name = NULL)
}
\arguments{
\item{wf_summary}{The workflow summary object}

\item{step_tmpl}{A step template function, see the Step Template section for
details.}

\item{sbatch_opts}{A named list of sbatch options to overwrite or complement
the default ones (default = NULL). (see the SBATCH Options section for
details).}

\item{step_name}{An optional name for the step}
}
\value{
The updated workflow summary
}
\description{
Add a Step to an Existing Workflow
}
\section{Step Template}{

A step template is a
\href{https://adv-r.hadley.nz/function-factories.html}{function factory} used to
simplify the setup of a step. The \code{slurmworkflow} package provides several
simple ones like \code{step_tmpl_bash_script} that takes a bash script to be run
as argument or \code{step_tmpl_r_script} that takes an R script to be run as
argument with an optional \code{setup_script} to load the required modules
beforehand.
}

\section{SBATCH Options}{

The \code{sbatch_opts} named list accepts all existing arguments to sbatch. It
only works with the long form (e.g. "job-name" instead of "J"). The full list
of arguments is available in the
\href{https://slurm.schedmd.com/sbatch.html}{sbacth documentation}. Some arguments
like "mem", "mem-per-cpu" and "mem-per-gpu" are mutually exclusive, providing
multiple of them will result in an error. However, if one is set at the
creation of the workflow in \code{default_sbatch_opts} (e.g. "mem") and another
at the addition of a step in \code{sbatch_opts} (e.g. "mem-per-gpu"), the second
one will be used.
}

\examples{
\dontrun{
wf <- add_workflow_step(
  step_tmpl_r_script(r_script = "R/abce-abc.R", setup_script = "loadR.sh"),
  sbatch_opts = list(
    "mem-per-cpu" = "4G",
    "cpus-per-task" = 28,
    "time" = 500
  ),
  step_name = "abc"
)
}

}
