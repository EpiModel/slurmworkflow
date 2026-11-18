test_that("bash engine tests pass through the fake Slurm", {
  skip_on_os("windows")
  bash <- Sys.which("bash")
  skip_if(!nzchar(bash), "bash is not available")
  script <- test_path("..", "runtime", "test-engine.sh")
  skip_if_not(file.exists(script), "tests/runtime/test-engine.sh is not available")
  # The engine suite copies inst/templates/workflow from the source tree.
  repo_root <- file.path(dirname(script), "..", "..")
  skip_if_not(
    file.exists(file.path(repo_root, "inst", "templates", "workflow", "swf")),
    "the package source tree is not available"
  )

  scratch <- withr::local_tempdir()
  withr::local_envvar(c(TEST_TMP = file.path(scratch, "engine")))
  output <- suppressWarnings(system2(
    bash, shQuote(normalizePath(script)),
    stdout = TRUE, stderr = TRUE
  ))
  status <- attr(output, "status")
  if (is.null(status)) {
    status <- 0L
  }
  expect(
    status == 0L,
    paste(c("test-engine.sh failed:", output), collapse = "\n")
  )
  expect_true(any(grepl("Result: PASS", output, fixed = TRUE)))
})
