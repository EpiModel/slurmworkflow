# Helper functions related to SBATCH options.

#' @keywords internal
#' @noRd
update_sbatch_opts <- function(cur_opts, update_opts) {
  update_opts <- clean_sbatch_opts(update_opts)
  sbatch_opts <- remove_conflicting_sbatch_opts(cur_opts, update_opts)
  sbatch_opts[names(update_opts)] <- update_opts
  validate_sbatch_opts(sbatch_opts)
}

#' Remove options from `cur_opts` that conflict with `update_opts`.
#' @keywords internal
#' @noRd
remove_conflicting_sbatch_opts <- function(cur_opts, update_opts) {
  conflicting_opts <- Filter(
    function(x) any(x %in% names(update_opts)),
    get_exclusive_sbatch_opts()
  )
  cur_opts[unlist(conflicting_opts)] <- NULL
  cur_opts
}

#' Check and clean an `sbatch_opts` list.
#' @keywords internal
#' @noRd
validate_sbatch_opts <- function(sbatch_opts) {
  sbatch_opts <- clean_sbatch_opts(sbatch_opts)
  if (length(sbatch_opts) > 0L &&
      (is.null(names(sbatch_opts)) || any(!nzchar(names(sbatch_opts))))) {
    stop("Every SBATCH option must have a name.", call. = FALSE)
  }
  if (anyDuplicated(names(sbatch_opts))) {
    stop("SBATCH options must have unique names.", call. = FALSE)
  }
  check_valid_sbatch_opts(sbatch_opts)
  check_reserved_sbatch_opts(sbatch_opts)
  check_exclusive_sbatch_opts(sbatch_opts)
  sbatch_opts
}

#' @keywords internal
#' @noRd
clean_sbatch_opts <- function(sbatch_opts) {
  if (is.null(sbatch_opts)) {
    return(list())
  }
  Filter(function(x) !is.null(x), as.list(sbatch_opts))
}

#' @keywords internal
#' @noRd
check_valid_sbatch_opts <- function(sbatch_opts) {
  incorrect_opts <- !names(sbatch_opts) %in% get_sbatch_opts_list()
  if (any(incorrect_opts)) {
    stop(
      "The following SBATCH options are not valid: \n    `",
      paste0(names(sbatch_opts)[incorrect_opts], collapse = "`, `"), "`\n",
      "Use only the long form (e.g. `account` and not `A`).",
      call. = FALSE
    )
  }
}

#' @keywords internal
#' @noRd
check_reserved_sbatch_opts <- function(sbatch_opts) {
  reserved <- intersect(names(sbatch_opts), get_reserved_sbatch_opts())
  if (length(reserved) > 0L) {
    stop(
      "The following SBATCH options are managed by slurmworkflow and cannot be set: ",
      paste0(reserved, collapse = ", "),
      call. = FALSE
    )
  }
}

#' @keywords internal
#' @noRd
check_exclusive_sbatch_opts <- function(sbatch_opts) {
  for (exclusive_opts in get_exclusive_sbatch_opts()) {
    exclusive_pos <- which(exclusive_opts %in% names(sbatch_opts))
    if (length(exclusive_pos) > 1L) {
      stop(
        "The following SBATCH options are mutually exclusive: ",
        paste0(exclusive_opts[exclusive_pos], collapse = ", "),
        call. = FALSE
      )
    }
  }
}

#' Return a list of mutually exclusive SBATCH options.
#' @keywords internal
#' @noRd
get_exclusive_sbatch_opts <- function() {
  list(
    mem = c("mem", "mem-per-cpu", "mem-per-gpu"),
    threads = c("extra-node-info", "hint", "threads-per-core", "ntasks-per-core")
  )
}

#' Options managed directly by the workflow engine.
#' @keywords internal
#' @noRd
get_reserved_sbatch_opts <- function() {
  c("dependency", "job-name", "output", "parsable")
}

#' List all valid SBATCH options.
#' @keywords internal
#' @noRd
get_sbatch_opts_list <- function() {
  c(
    "account", "acctg-freq", "array", "batch", "bb", "bbf", "begin",
    "chdir", "cluster-constraint", "clusters", "comment", "constraint",
    "container", "contiguous", "core-spec", "cores-per-socket", "cpu-freq",
    "cpus-per-gpu", "cpus-per-task", "deadline", "delay-boot", "dependency",
    "distribution", "error", "exclude", "exclusive", "export", "export-file",
    "extra-node-info", "get-user-env", "gid", "gpu-bind", "gpu-freq", "gpus",
    "gpus-per-node", "gpus-per-socket", "gpus-per-task", "gres", "gres-flags",
    "help", "hint", "hold", "ignore-pbs", "input", "job-name",
    "kill-on-invalid-dep", "licenses", "mail-type", "mail-user", "mcs-label",
    "mem", "mem-bind", "mem-per-cpu", "mem-per-gpu", "mincpus", "network",
    "nice", "no-requeue", "nodefile", "nodelist", "nodes", "ntasks",
    "ntasks-per-core", "ntasks-per-gpu", "ntasks-per-node",
    "ntasks-per-socket", "open-mode", "output", "overcommit", "oversubscribe",
    "parsable", "partition", "power", "priority", "profile", "propagate",
    "qos", "quiet", "reboot", "requeue", "reservation", "signal",
    "sockets-per-node", "spread-job", "switches", "test-only", "thread-spec",
    "threads-per-core", "time", "time-min", "tmp", "uid", "usage",
    "use-min-nodes", "verbose", "wait", "wait-all-nodes", "wckey", "wrap"
  )
}
