bash_version_ok <- function() {
  out <- system2("bash", c("-c", "echo ${BASH_VERSINFO[0]}"),
    stdout = TRUE, stderr = FALSE
  )
  !is.null(out) &&
    length(out) == 1L &&
    !is.na(suppressWarnings(as.integer(out))) &&
    as.integer(out) >= 4L
}

test_that("runtime shell harness passes", {
  skip_on_os("windows")
  skip_if_not(bash_version_ok(), "bash 4+ is required")

  harness <- system.file("tests", "runtime", "test-step-shell.sh",
    package = "slurmworkflow"
  )
  if (harness == "") {
    harness <- file.path("..", "runtime", "test-step-shell.sh")
  }
  skip_if_not(file.exists(harness), "runtime harness not found")

  out <- system2("bash", harness, stdout = TRUE, stderr = TRUE)
  expect_true(any(grepl("All expected behaviors matched\\.", out)),
    info = paste(out, collapse = "\n")
  )
})
