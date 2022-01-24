test_that("error occurs when calling functions outside of HPC", {
  expect_error(get_workflow_root())
  expect_warning(change_next_workflow_step(2))
})

test_that("flow alteration errors on invalid step definition", {
  nextstepfile <- "nextstepfile"
  withr::local_file(nextstepfile)
  Sys.setenv("SWF_NEXTSTEP_FILE" = nextstepfile)

  expect_error(change_next_workflow_step("two"))

  Sys.setenv("SWF_NEXTSTEP_FILE" = "")
})
