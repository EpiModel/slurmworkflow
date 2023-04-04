#' @noRd
expect_dir_exists <- function(object) {
  act <- testthat::quasi_label(rlang::enquo(object), arg = "object")
  testthat::expect(
    fs::dir_exists(act$val),
    sprintf(
      "\"%s\" in variable %s is not a path to an existing directory.",
      act$val, act$lab
    )
  )
  invisible(act$val)
}

#' @noRd
expect_file_exists <- function(object) {
  act <- testthat::quasi_label(rlang::enquo(object), arg = "object")
  testthat::expect(
    fs::file_exists(act$val),
    sprintf(
      "\"%s\" in variable %s is not a path to an existing file.",
      act$val, act$lab
    )
  )
  invisible(act$val)
}
