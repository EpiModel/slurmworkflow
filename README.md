
<!-- README.md is generated from README.Rmd. Please edit that file -->

# slurmworkflow

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![CRAN
status](https://www.r-pkg.org/badges/version/slurmworkflow)](https://CRAN.R-project.org/package=slurmworkflow)
[![R-CMD-check](https://github.com/EpiModel/slurmworkflow/workflows/R-CMD-check/badge.svg)](https://github.com/EpiModel/slurmworkflow/actions)
[![codecov](https://codecov.io/gh/EpiModel/slurmworkflow/branch/main/graph/badge.svg?token=eo2r0HeP8Z)](https://codecov.io/gh/EpiModel/slurmworkflow)
<!-- badges: end -->

**slurmworkflow** allows people working with an slurm equipped HPC to
define workflows locally and run them on the HPC without the need of a
long lived job or a persistent SSH session.

A workflow is a predefined set of steps (slurm jobs) to be executed on
an HPC. By default each step is run in order, but **slurmworkflow**
provides tools for altering the execution order, allowing conditional
execution of the steps and loop like behavior.

## Installation

You can install the development version of slurmworkflow like so:

``` r
remotes::install_github("EpiModel/slurmworkflow")
```

## Example

``` r
library(slurmworkflow)
```
