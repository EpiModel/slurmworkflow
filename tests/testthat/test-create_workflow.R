test_that("`create_workflow` produces the right file structure", {
  test_dir <- "workflows"
  withr::local_file(test_dir)

  wf_name <- "test_wf"

  wf <- create_workflow(
    wf_name = wf_name,
    default_sbatch_opts = list(
      "account" = "test_account"
    ),
    wf_common_dir = test_dir
  )

  wf_root <- get_workflow_root(wf)
  expect_dir_exists(wf_root)

  wf_vars <- make_wf_vars(wf)
  expect_dir_exists(wf_vars[["SWF_ROOT"]])
  expect_dir_exists(wf_vars[["SWF__DIR"]])

  start_wf_script <- fs::path(wf_vars[["SWF_ROOT"]], "start_workflow.sh")
  expect_file_exists(start_wf_script)
  expect_file_exists(wf_vars[["SWF_SUMMARY"]])
  expect_file_exists(wf_vars[["SWF__CTRL_SCRIPT"]])
  expect_file_exists(wf_vars[["SWF__STEP_SCRIPT"]])
})

test_that("`create_workflow` fails if a workflow with the same name already exists", {
  test_dir <- "workflows"
  withr::local_file(test_dir)

  wf_name <- "test_wf"

  create_workflow(
    wf_name = wf_name,
    default_sbatch_opts = list(
      "account" = "test_account"
    ),
    wf_common_dir = test_dir
  )

  expect_error(
    create_workflow(
      wf_name = wf_name,
      default_sbatch_opts = list(
        "account" = "test_account"
        ),
      wf_common_dir = test_dir
    )
  )
})
