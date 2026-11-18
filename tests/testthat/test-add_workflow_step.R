test_that("add_workflow_step creates named directories and resolved data", {
  directory <- withr::local_tempdir()
  wf <- create_workflow(
    "steps",
    list(partition = "compute", mem = "8G", time = 60),
    directory
  )

  template <- function(instructions_script, wf_vars, wf_summary, sbatch_opts, ...) {
    expect_true(dir.exists(wf_vars[["SWF__CUR_DIR"]]))
    expect_identical(sbatch_opts[["mem"]], "8G")
    writeLines("echo first", instructions_script)
    list(
      sbatch_opts = list(`mem-per-cpu` = "4G"),
      data = list(alpha = "a=b # literal", count = 100000)
    )
  }
  wf <- add_workflow_step(
    wf, template, step_name = "first_step", next_step = "finish-later"
  )

  step_dir <- file.path(wf[["root"]], "swf.d", "steps", "1_first_step")
  expect_true(dir.exists(step_dir))
  expect_true(file.exists(file.path(step_dir, "instructions.sh")))
  expect_false(file.exists(file.path(step_dir, "job.sh")))
  expect_named(wf[["steps"]][[1L]], c("number", "name", "next", "sbatch_opts", "data"))
  expect_identical(wf[["steps"]][[1L]][["number"]], 1L)
  expect_identical(wf[["steps"]][[1L]][["next"]], "finish-later")
  expect_identical(wf[["steps"]][[1L]][["sbatch_opts"]][["mem-per-cpu"]], "4G")
  expect_false("mem" %in% names(wf[["steps"]][[1L]][["sbatch_opts"]]))

  contents <- read_swf(file.path(step_dir, "step.swf"))
  expect_identical(contents[["next"]], "finish-later")
  expect_identical(contents[["data.alpha"]], "a=b # literal")
  expect_identical(contents[["data.count"]], "100000")
  expect_identical(contents[["opt.time"]], "60")
  expect_identical(wf, load_workflow(wf[["root"]]))
})

test_that("step names, defaults, and static successors are validated", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("names", list(partition = "compute"), directory)
  bash <- step_tmpl_bash_lines("true")
  wf <- add_workflow_step(wf, bash)
  expect_identical(wf[["steps"]][[1L]][["name"]], "step_1")
  expect_null(wf[["steps"]][[1L]][["next"]])

  wf <- add_workflow_step(wf, bash, next_step = 1)
  expect_identical(wf[["steps"]][[2L]][["name"]], "step_2")
  expect_identical(wf[["steps"]][[2L]][["next"]], "step_1")
  wf <- add_workflow_step(wf, bash, next_step = NA)
  expect_identical(wf[["steps"]][[3L]][["next"]], "")
  wf <- add_workflow_step(wf, bash, step_name = "finished", next_step = "")
  expect_identical(wf[["steps"]][[4L]][["next"]], "")

  expect_error(add_workflow_step(wf, bash, step_name = "finished"), "already")
  for (invalid in list("1numeric", "", "has space", "under_score.ok", NA_character_)) {
    expect_error(add_workflow_step(wf, bash, step_name = invalid), "step_name")
  }
  expect_error(add_workflow_step(wf, bash, next_step = 99), "Unknown")
  expect_error(add_workflow_step(wf, bash, next_step = 1.5), "whole")
  expect_error(add_workflow_step(wf, bash, next_step = "not a name"), "step_name")
})

test_that("template results merge exclusive options and reject malformed returns", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("templates", list(partition = "compute", mem = "4G"), directory)
  wf <- add_workflow_step(
    wf,
    step_tmpl = function(instructions_script, ...) {
      writeLines("true", instructions_script)
      list(sbatch_opts = list(`mem-per-gpu` = "2G"))
    },
    sbatch_opts = list(`mem-per-cpu` = "8G")
  )
  options <- wf[["steps"]][[1L]][["sbatch_opts"]]
  expect_named(options, c("partition", "mem-per-gpu"))

  expect_error(
    add_workflow_step(
      wf,
      function(instructions_script, ...) list(array = "0-2")
    ),
    "only contain"
  )
  expect_error(
    add_workflow_step(
      wf,
      function(instructions_script, ...) list(data = list(1, 2))
    ),
    "named list"
  )
})

test_that("step_tmpl_map writes map data and an array without export", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("map", list(partition = "compute"), directory)
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      function(x, fixed) x + fixed,
      x = 1:5,
      MoreArgs = list(fixed = 2),
      max_array_size = 3
    ),
    step_name = "mapped",
    next_step = NA
  )
  step <- wf[["steps"]][[1L]]
  expect_identical(step[["sbatch_opts"]][["array"]], "0-2")
  expect_false("export" %in% names(step[["sbatch_opts"]]))
  expect_identical(
    step[["data"]],
    list(map.n_items = "5", map.max_array_size = "3",
         map.offset = "0", map.total = "5")
  )
  expect_identical(step[["next"]], "")

  step_dir <- file.path(wf[["root"]], "swf.d", "steps", "1_mapped")
  expect_true(file.exists(file.path(step_dir, "script.R")))
  expect_true(file.exists(file.path(step_dir, "map.rds")))
  map_data <- readRDS(file.path(step_dir, "map.rds"))
  expect_identical(map_data[["dots"]], list(x = 1:5))
  expect_false("array_size" %in% names(map_data))

  expect_error(step_tmpl_map(identity), "at least one")
  expect_error(step_tmpl_map(identity, integer()), "empty")
  expect_error(step_tmpl_map(identity, x = 1:2, y = 1:3), "same length")
  expect_error(step_tmpl_map(identity, 1:2, max_array_size = 0), "positive")
})

test_that("infinite map array size is stored as the finite item count", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("map-infinite", list(partition = "compute"), directory)
  wf <- add_workflow_step(wf, step_tmpl_map(identity, letters[1:2]))
  expect_identical(wf[["steps"]][[1L]][["data"]][["map.max_array_size"]], "2")
  expect_identical(wf[["steps"]][[1L]][["sbatch_opts"]][["array"]], "0-1")
})
