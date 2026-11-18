test_that("create_workflow writes the engine and resolved SWF files", {
  directory <- withr::local_tempdir()
  wf <- create_workflow(
    wf_name = "my-workflow",
    default_sbatch_opts = list(
      partition = "compute",
      account = "project",
      mem = "8G",
      time = 180
    ),
    wf_common_dir = directory
  )
  root <- wf[["root"]]

  expect_true(dir.exists(root))
  expect_true(file.exists(file.path(root, "swf")))
  expect_identical(unname(file.access(file.path(root, "swf"), mode = 1L)), 0L)
  expect_setequal(
    list.files(file.path(root, "swf.d")),
    c("lib.sh", "controller.sh", "job.sh", "workflow.swf",
      "sbatch_rules.swf", "steps")
  )
  expect_false(file.exists(file.path(root, "workflow.yaml")))
  expect_false(file.exists(file.path(root, "start_workflow.sh")))

  workflow <- read_swf(file.path(root, "swf.d", "workflow.swf"))
  expect_identical(workflow[["opt.partition"]], "compute")
  expect_identical(workflow[["opt.time"]], "180")
  expect_identical(workflow[["ctrl.opt.partition"]], "compute")
  expect_identical(workflow[["ctrl.opt.account"]], "project")

  rules <- read_swf(file.path(root, "swf.d", "sbatch_rules.swf"))
  expect_identical(rules[["exclusive.mem"]], "mem mem-per-cpu mem-per-gpu")
  expect_identical(rules[["reserved"]], "dependency job-name output parsable")
  expect_true("partition" %in% strsplit(rules[["valid"]], " ", fixed = TRUE)[[1L]])
  expect_identical(wf, load_workflow(root))
  expect_named(wf, c("name", "root", "default_sbatch_opts", "steps"))
  expect_length(wf[["steps"]], 0L)
})

test_that("create_workflow validates names, partitions, and reserved options", {
  directory <- withr::local_tempdir()
  expect_error(
    create_workflow("one", list(account = "project"), directory),
    "partition"
  )

  wf <- create_workflow("one", list(partition = "compute"), directory)
  expect_error(
    create_workflow("one", list(partition = "compute"), directory),
    "already exists"
  )
  for (option in get_reserved_sbatch_opts()) {
    expect_error(
      create_workflow(
        option,
        setNames(list(partition = "compute", "anything"),
                 c("partition", option)),
        directory
      ),
      "managed"
    )
  }
  expect_error(
    add_workflow_step(
      wf,
      step_tmpl_bash_lines("true"),
      sbatch_opts = list(`job-name` = "custom")
    ),
    "managed"
  )
})
