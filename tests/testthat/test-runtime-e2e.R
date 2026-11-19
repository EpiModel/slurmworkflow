# End-to-end runtime scenarios: workflows built with the R API and run through
# the fake Slurm in tests/fake_slurm. Payloads run in fresh Rscript processes
# that load the *installed* slurmworkflow, so they only see absolute paths
# passed as arguments.

fake_slurm_bin <- function() {
  path <- test_path("..", "fake_slurm")
  if (!dir.exists(path)) {
    return("")
  }
  normalizePath(path)
}

skip_if_no_runtime <- function() {
  skip_if_no_engine_bash()
  skip_if(!nzchar(Sys.which("bash")), "bash is not available")
  bin <- fake_slurm_bin()
  skip_if(
    !nzchar(bin) || !file.exists(file.path(bin, "fake_slurm_run")),
    "the fake Slurm scripts are not available"
  )
  # `lib.loc` bypasses the namespace loaded by pkgload: the jobs use the
  # installed package, which must be a dynamic-steps (>= 0.2.0) version.
  installed <- base::system.file(
    "templates", "workflow", "swf",
    package = "slurmworkflow", lib.loc = .libPaths()
  )
  skip_if(!nzchar(installed), "an up-to-date slurmworkflow is not installed")
}

# Isolated scheduler state, workflow, working and output directories, with the
# fake Slurm first on PATH and the library paths forwarded to the jobs.
local_swf_runtime <- function(env = parent.frame()) {
  skip_if_no_runtime()
  tmp <- normalizePath(withr::local_tempdir(.local_envir = env))
  rt <- list(
    bin = fake_slurm_bin(),
    workflows = file.path(tmp, "workflows"),
    fake = file.path(tmp, "fake"),
    work = file.path(tmp, "work"),
    out = file.path(tmp, "out")
  )
  for (dir in rt[c("workflows", "fake", "work", "out")]) {
    dir.create(dir)
  }
  withr::local_envvar(
    c(
      PATH = paste(rt$bin, R.home("bin"), Sys.getenv("PATH"), sep = ":"),
      FAKE_SLURM_DIR = rt$fake,
      FAKE_SLURM_KEEP_ENV = "R_LIBS",
      R_LIBS = paste(.libPaths(), collapse = ":"),
      SWF_ROOT = NA, SWF_CMD = NA, SWF_RUN_ID = NA, SWF_CUR = NA,
      SWF_CUR_NAME = NA, SWF_SUBMISSION = NA, SLURM_JOB_ID = NA,
      SLURM_ARRAY_JOB_ID = NA, SLURM_ARRAY_TASK_ID = NA
    ),
    .local_envir = env
  )
  rt
}

# Payload functions are serialized; detach them from the test environment.
payload <- function(f) {
  environment(f) <- globalenv()
  f
}

run_cmd <- function(command, args = character()) {
  output <- suppressWarnings(system2(
    command, shQuote(args),
    stdout = TRUE, stderr = TRUE
  ))
  status <- attr(output, "status")
  list(status = if (is.null(status)) 0L else status, output = output)
}

read_history <- function(run_dir) {
  lines <- readLines(file.path(run_dir, "history"))
  lapply(strsplit(lines, " ", fixed = TRUE), function(fields) {
    stats::setNames(sub("^[^=]*=", "", fields), sub("=.*$", "", fields))
  })
}

# Start the workflow from the working directory and run the fake scheduler
# until nothing is runnable.
run_workflow <- function(rt, wf) {
  start <- withr::with_dir(rt$work, run_cmd(file.path(wf$root, "swf"), "start"))
  if (start$status != 0L) {
    stop("swf start failed:\n", paste(start$output, collapse = "\n"))
  }
  run_id <- utils::tail(start$output, 1L)
  scheduler <- run_cmd(file.path(rt$bin, "fake_slurm_run"))
  run_dir <- file.path(wf$root, "swf.d", "run", run_id)
  log_dir <- file.path(wf$root, "log", run_id)
  if (scheduler$status != 0L) {
    stop(
      "fake_slurm_run failed:\n", paste(scheduler$output, collapse = "\n"),
      "\ncontroller log:\n",
      paste(readLines(file.path(log_dir, "controller.out")), collapse = "\n")
    )
  }
  list(
    root = wf$root,
    id = run_id,
    dir = run_dir,
    log_dir = log_dir,
    history = read_history(run_dir),
    scheduler = scheduler$output
  )
}

events <- function(run, event) {
  Filter(function(x) identical(x[["event"]], event), run$history)
}

# Submissions (step, job, from) in history order, optionally for one step.
submissions <- function(run, step = NULL) {
  subs <- events(run, "submit")
  if (!is.null(step)) {
    subs <- Filter(function(x) identical(x[["step"]], step), subs)
  }
  subs
}

submitted_steps <- function(run) {
  vapply(submissions(run), function(x) x[["step"]], character(1L))
}

# Exact argv recorded by the fake sbatch (NUL-delimited).
job_argv <- function(rt, job) {
  path <- file.path(rt$fake, "jobs", job, "argv")
  raw <- readBin(path, "raw", n = file.size(path))
  ends <- which(raw == as.raw(0L))
  starts <- c(1L, utils::head(ends, -1L) + 1L)
  mapply(function(s, e) {
    if (e > s) rawToChar(raw[s:(e - 1L)]) else ""
  }, starts, ends, USE.NAMES = FALSE)
}

expect_run_ended <- function(run) {
  last <- run$history[[length(run$history)]]
  controller <- file.path(run$log_dir, "controller.out")
  expect(
    identical(last[["event"]], "end"),
    paste(c(
      "the run did not end; history:",
      readLines(file.path(run$dir, "history")),
      "controller log:",
      if (file.exists(controller)) readLines(controller)
    ), collapse = "\n")
  )
  expect_length(events(run, "error"), 0L)
  expect_length(list.files(file.path(run$dir, "msg", "override")), 0L)
  expect_false(file.exists(file.path(run$dir, "msg", "next.swf")))
}

expect_no_failures <- function(run) {
  expect_identical(list.files(file.path(run$dir, "failed")), character())
}

new_test_workflow <- function(rt, name, ...) {
  create_workflow(
    name,
    list(partition = "test", ...),
    wf_common_dir = rt$workflows
  )
}

bash_write <- function(path, text) {
  step_tmpl_bash_lines(paste0(
    "printf '%s\\n' ", shQuote(text), " >> ", shQuote(path)
  ))
}

# a. swfcalib-like loop --------------------------------------------------------

build_calib_loop <- function(workflows, out) {
  counter <- file.path(out, "iteration")
  items <- file.path(out, "items")
  done <- file.path(out, "done")
  wf <- create_workflow("calib", list(partition = "test"), workflows)
  wf <- add_workflow_step(
    wf,
    step_tmpl_do_call(
      payload(function(counter, sizes) {
        i <- if (file.exists(counter)) as.integer(readLines(counter)) + 1L else 1L
        writeLines(as.character(i), counter)
        if (i <= length(sizes)) {
          slurmworkflow::set_map_size("work", sizes[[i]])
        } else {
          slurmworkflow::change_next_workflow_step("wrap")
        }
      }),
      list(counter = counter, sizes = c(3, 5, 2))
    ),
    step_name = "plan"
  )
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      payload(function(idx, counter, items) {
        cat(readLines(counter), "_", idx, "\n", file = items, append = TRUE,
            sep = "")
      }),
      idx = 1:5,
      MoreArgs = list(counter = counter, items = items)
    ),
    step_name = "work",
    next_step = "plan"
  )
  wf <- add_workflow_step(
    wf,
    step_tmpl_do_call(
      payload(function(done) cat("done\n", file = done, append = TRUE)),
      list(done = done)
    ),
    step_name = "wrap"
  )
  list(wf = wf, counter = counter, items = items, done = done)
}

test_that("a swfcalib-like loop resizes the map each iteration then exits", {
  rt <- local_swf_runtime()
  built <- build_calib_loop(rt$workflows, rt$out)
  wf <- built$wf
  work_step <- file.path(wf$root, "swf.d", "steps", "2_work", "step.swf")
  work_before <- readLines(work_step)

  run <- run_workflow(rt, wf)

  expect_run_ended(run)
  expect_no_failures(run)
  expect_identical(
    submitted_steps(run),
    c(rep(c("1_plan", "2_work"), 3), "1_plan", "3_wrap")
  )
  expect_identical(readLines(built$counter), "4")
  expect_identical(readLines(built$items), c(
    paste0("1_", 1:3), paste0("2_", 1:5), paste0("3_", 1:2)
  ))
  expect_identical(readLines(built$done), "done")

  # Every work submission came from a claimed one-shot override.
  work_subs <- submissions(run, "2_work")
  expect_true(all(grepl("^run/.*/used/[0-9]+_override_work\\.swf$",
                        vapply(work_subs, `[[`, "", "from"))))
  arrays <- vapply(work_subs, function(x) {
    grep("^--array=", job_argv(rt, x[["job"]]), value = TRUE)
  }, character(1L))
  expect_identical(arrays, c("--array=0-2", "--array=0-4", "--array=0-1"))
  used <- list.files(file.path(run$dir, "used"))
  expect_length(grep("_override_work\\.swf$", used), 3L)
  expect_length(grep("_next\\.swf$", used), 1L)

  # The design is untouched by the run.
  expect_identical(readLines(work_step), work_before)
})

# b. set_map_size(0) skips the map --------------------------------------------

build_resize_then_map <- function(rt, name, size, on_failure = "stop",
                                  array_throttle = NULL, max_array_size = Inf) {
  items <- file.path(rt$out, "items")
  after <- file.path(rt$out, "after")
  wf <- new_test_workflow(rt, name)
  wf <- add_workflow_step(
    wf,
    step_tmpl_do_call(
      payload(function(n) slurmworkflow::set_map_size("mapped", n)),
      list(n = size)
    ),
    step_name = "resize",
    on_failure = on_failure
  )
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      payload(function(idx, items) cat(idx, "\n", file = items,
                                       append = TRUE, sep = "")),
      idx = 1:5,
      MoreArgs = list(items = items),
      max_array_size = max_array_size,
      array_throttle = array_throttle
    ),
    step_name = "mapped"
  )
  wf <- add_workflow_step(wf, bash_write(after, "after"), step_name = "after")
  list(wf = wf, items = items, after = after)
}

test_that("set_map_size(0) skips the map step and the workflow continues", {
  rt <- local_swf_runtime()
  built <- build_resize_then_map(rt, "zero", 0)

  run <- run_workflow(rt, built$wf)

  expect_run_ended(run)
  expect_no_failures(run)
  expect_identical(submitted_steps(run), c("1_resize", "3_after"))
  skips <- events(run, "skip")
  expect_length(skips, 1L)
  expect_identical(skips[[1L]][["step"]], "2_mapped")
  expect_false(file.exists(built$items))
  expect_identical(readLines(built$after), "after")
})

# c. a failed step stops the workflow, unless on_failure = "continue" ---------

expect_run_stopped_on <- function(run, step, n_failed = 1L) {
  last <- run$history[[length(run$history)]]
  controller <- file.path(run$log_dir, "controller.out")
  expect(
    identical(last[["event"]], "error") &&
      identical(last[["reason"]], paste0("step_failed:", step)),
    paste(c(
      paste0("the run did not stop on step_failed:", step, "; history:"),
      readLines(file.path(run$dir, "history")),
      "controller log:",
      if (file.exists(controller)) readLines(controller)
    ), collapse = "\n")
  )
  expect_identical(last[["failed"]], as.character(n_failed))
  expect_length(events(run, "end"), 0L)
  expect_length(list.files(file.path(run$dir, "failed")), n_failed)
}

expect_resize_failed <- function(rt, run) {
  resize_job <- submissions(run, "1_resize")[[1L]][["job"]]
  failed <- list.files(file.path(run$dir, "failed"))
  expect_identical(failed, resize_job)
  expect_false(identical(readLines(file.path(run$dir, "failed", resize_job)), "0"))
  expect_identical(
    readLines(file.path(rt$fake, "jobs", resize_job, "state")), "FAILED"
  )
  resize_log <- readLines(list.files(
    run$log_dir, pattern = paste0("^1_resize_", resize_job, "_"),
    full.names = TRUE
  ))
  expect_true(any(grepl("cannot exceed", resize_log, fixed = TRUE)))
}

test_that("set_map_size above n_items fails the job and stops the workflow", {
  rt <- local_swf_runtime()
  built <- build_resize_then_map(rt, "toobig", 6)

  run <- run_workflow(rt, built$wf)

  expect_run_stopped_on(run, "1_resize")
  expect_resize_failed(rt, run)
  expect_identical(submitted_steps(run), "1_resize")
  expect_false(file.exists(built$items))
  expect_false(file.exists(built$after))
})

test_that("with on_failure = \"continue\", the workflow goes on", {
  rt <- local_swf_runtime()
  built <- build_resize_then_map(rt, "toobig", 6, on_failure = "continue")
  expect_identical(built$wf$steps[[1L]]$on_failure, "continue")

  run <- run_workflow(rt, built$wf)

  expect_run_ended(run)
  expect_resize_failed(rt, run)
  # No override was written: the map runs with its built size, then `after`.
  expect_identical(submitted_steps(run), c("1_resize", "2_mapped", "3_after"))
  expect_identical(
    submissions(run, "2_mapped")[[1L]][["from"]], "steps/2_mapped/step.swf"
  )
  expect_identical(readLines(built$items), as.character(1:5))
  expect_identical(readLines(built$after), "after")
})

test_that("array_throttle reaches every slice, including set_map_size", {
  rt <- local_swf_runtime()
  built <- build_resize_then_map(
    rt, "throttled", 3, array_throttle = 1, max_array_size = 2
  )
  expect_identical(built$wf$steps[[2L]]$sbatch_opts$array, "0-1%1")

  run <- run_workflow(rt, built$wf)

  expect_run_ended(run)
  expect_no_failures(run)
  expect_identical(
    submitted_steps(run), c("1_resize", "2_mapped", "2_mapped", "3_after")
  )
  arrays <- vapply(submissions(run, "2_mapped"), function(x) {
    grep("^--array=", job_argv(rt, x[["job"]]), value = TRUE)
  }, character(1L))
  expect_identical(arrays, c("--array=0-1%1", "--array=0-0%1"))
  expect_identical(sort(as.integer(readLines(built$items))), 1:3)
})

test_that("an array override that does not cover the slice fails every task", {
  rt <- local_swf_runtime()
  items <- file.path(rt$out, "items")
  after <- file.path(rt$out, "after")
  wf <- new_test_workflow(rt, "badarray")
  wf <- add_workflow_step(
    wf,
    step_tmpl_do_call(
      payload(function() {
        slurmworkflow::override_workflow_step(
          "mapped", sbatch_opts = list(array = "0-1")
        )
      }),
      list()
    ),
    step_name = "shrink"
  )
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      payload(function(idx, items) cat(idx, "\n", file = items,
                                       append = TRUE, sep = "")),
      idx = 1:5,
      MoreArgs = list(items = items)
    ),
    step_name = "mapped"
  )
  wf <- add_workflow_step(wf, bash_write(after, "after"), step_name = "after")

  run <- run_workflow(rt, wf)

  expect_run_stopped_on(run, "2_mapped", n_failed = 2L)
  expect_identical(submitted_steps(run), c("1_shrink", "2_mapped"))
  expect_false(file.exists(items))
  expect_false(file.exists(after))
  job <- submissions(run, "2_mapped")[[1L]][["job"]]
  logs <- list.files(run$log_dir, pattern = paste0("^2_mapped_", job, "_"),
                     full.names = TRUE)
  expect_length(logs, 2L)
  for (log in logs) {
    expect_true(any(grepl(
      "Expected 5 tasks numbered 0-4 .* got 2 tasks numbered 0-1",
      readLines(log)
    )))
  }
})

# d. map slices ----------------------------------------------------------------

test_that("map slices run sequentially and a next message waits for the last", {
  rt <- local_swf_runtime()
  items <- file.path(rt$out, "items")
  between <- file.path(rt$out, "between")
  last <- file.path(rt$out, "last")
  wf <- new_test_workflow(rt, "slices")
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      payload(function(idx, items) {
        if (idx == 1L) {
          slurmworkflow::change_next_workflow_step("last")
        }
        cat(idx, "\n", file = items, append = TRUE, sep = "")
      }),
      idx = 1:7,
      MoreArgs = list(items = items),
      max_array_size = 3
    ),
    step_name = "mapped"
  )
  wf <- add_workflow_step(wf, bash_write(between, "between"),
                          step_name = "between")
  wf <- add_workflow_step(
    wf,
    step_tmpl_do_call(
      payload(function(items, last) {
        writeLines(as.character(length(readLines(items))), last)
      }),
      list(items = items, last = last)
    ),
    step_name = "last"
  )
  expect_identical(wf$steps[[1L]]$sbatch_opts$array, "0-2")

  run <- run_workflow(rt, wf)

  expect_run_ended(run)
  expect_no_failures(run)
  expect_identical(
    submitted_steps(run),
    c("1_mapped", "1_mapped", "1_mapped", "3_last")
  )
  expect_false(file.exists(between))
  expect_identical(sort(as.integer(readLines(items))), 1:7)
  # `last` ran after the final slice had processed every item.
  expect_identical(readLines(last), "7")

  mapped <- submissions(run, "1_mapped")
  arrays <- vapply(mapped, function(x) {
    grep("^--array=", job_argv(rt, x[["job"]]), value = TRUE)
  }, character(1L))
  expect_identical(arrays, c("--array=0-2", "--array=0-2", "--array=0-0"))
  froms <- vapply(mapped, `[[`, "", "from")
  expect_identical(froms[[1L]], "steps/1_mapped/step.swf")
  expect_match(froms[2:3], "^run/.*/used/[0-9]+_override_mapped\\.swf$")

  continuations <- lapply(
    file.path(wf$root, "swf.d", froms[2:3]),
    read_swf
  )
  for (i in 1:2) {
    expect_identical(continuations[[i]][["repeat"]], "1")
    expect_identical(continuations[[i]][["data.map.total"]], "7")
  }
  expect_identical(continuations[[1L]][["data.map.offset"]], "3")
  expect_identical(continuations[[1L]][["opt.array"]], "0-2")
  expect_identical(continuations[[2L]][["data.map.offset"]], "6")
  expect_identical(continuations[[2L]][["opt.array"]], "0-0")

  # The next message was claimed once, by the controller after the last slice.
  used <- list.files(file.path(run$dir, "used"))
  next_used <- grep("_next\\.swf$", used, value = TRUE)
  expect_length(next_used, 1L)
  expect_identical(
    sub("_next\\.swf$", "", next_used),
    mapped[[3L]][["ctrl"]]
  )
})

# e. override with a nasty value from an R step ---------------------------------

test_that("an R override with spaces and `*` is one argv element, once", {
  rt <- local_swf_runtime()
  counter <- file.path(rt$out, "iteration")
  fin <- file.path(rt$out, "fin")
  nasty <- "a b * $HOME"
  wf <- new_test_workflow(rt, "nasty")
  wf <- add_workflow_step(
    wf,
    step_tmpl_do_call(
      payload(function(counter, value) {
        i <- if (file.exists(counter)) as.integer(readLines(counter)) + 1L else 1L
        writeLines(as.character(i), counter)
        if (i == 1L) {
          slurmworkflow::override_workflow_step(
            "target", sbatch_opts = list(comment = value)
          )
        } else if (i == 3L) {
          slurmworkflow::change_next_workflow_step("fin")
        }
      }),
      list(counter = counter, value = nasty)
    ),
    step_name = "ctl"
  )
  wf <- add_workflow_step(
    wf, step_tmpl_bash_lines("true"),
    sbatch_opts = list(comment = "default"),
    step_name = "target", next_step = "ctl"
  )
  wf <- add_workflow_step(wf, bash_write(fin, "fin"),
                          step_name = "fin", next_step = NA)

  run <- run_workflow(rt, wf)

  expect_run_ended(run)
  expect_no_failures(run)
  expect_identical(
    submitted_steps(run),
    c("1_ctl", "2_target", "1_ctl", "2_target", "1_ctl", "3_fin")
  )
  target <- submissions(run, "2_target")
  first <- job_argv(rt, target[[1L]][["job"]])
  second <- job_argv(rt, target[[2L]][["job"]])
  expect_identical(sum(first == paste0("--comment=", nasty)), 1L)
  expect_length(grep("^--comment=", first), 1L)
  expect_identical(sum(second == "--comment=default"), 1L)
  expect_length(grep("^--comment=", second), 1L)
  expect_match(target[[1L]][["from"]], "^run/.*/used/[0-9]+_override_target\\.swf$")
  expect_identical(target[[2L]][["from"]], "steps/2_target/step.swf")
  expect_identical(readLines(fin), "fin")
})

# f. load_workflow -------------------------------------------------------------

test_that("load_workflow rebuilds names, successors and data from the files", {
  tmp <- withr::local_tempdir()
  built <- build_calib_loop(tmp, tmp)
  wf <- load_workflow(built$wf$root)

  expect_identical(wf, built$wf)
  expect_identical(wf$name, "calib")
  expect_identical(wf$default_sbatch_opts, list(partition = "test"))
  steps <- wf$steps
  expect_identical(vapply(steps, `[[`, "", "name"), c("plan", "work", "wrap"))
  expect_identical(vapply(steps, `[[`, 0L, "number"), 1:3)
  expect_identical(lapply(steps, `[[`, "next"), list(NULL, "plan", NULL))
  expect_identical(steps[[1L]]$data, stats::setNames(list(), character()))
  expect_identical(steps[[2L]]$data, list(
    map.n_items = "5", map.max_array_size = "5",
    map.offset = "0", map.total = "5"
  ))
  expect_identical(
    steps[[2L]]$sbatch_opts,
    list(partition = "test", array = "0-4")
  )
})
