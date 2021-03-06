% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/step_templates.R
\name{step_tmpl_bash_lines}
\alias{step_tmpl_bash_lines}
\title{Step template to run bash statements}
\usage{
step_tmpl_bash_lines(bash_lines)
}
\arguments{
\item{bash_lines}{Vector of bash lines to be run by the workflow step}
}
\value{
a template function to be used by \code{add_workflow_step}
}
\description{
Step template to run bash statements
}
\section{Step Template}{

Step Templates are helper functions to be used within \code{add_workflow_step}.
Some basic ones are provided by the \code{slurmworkflow} package. They instruct
the workflow to run either a bash script, a set of bash lines given as a
character vector or an R script.
Additional Step Templates can be created to simplify specific tasks, see the
\code{vignette("making-a-custom-step-template")} for details.
}

