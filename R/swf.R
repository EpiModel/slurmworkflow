# Read and write the line-oriented SWF format without evaluating its contents.

#' @keywords internal
#' @noRd
read_swf <- function(path) {
  if (length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("`path` must be a non-empty path of length one.", call. = FALSE)
  }
  if (!file.exists(path) || dir.exists(path)) {
    stop("The SWF file does not exist: ", path, call. = FALSE)
  }

  size <- file.info(path)[["size"]]
  contents <- readBin(path, what = "raw", n = size)
  if (any(contents == as.raw(0L))) {
    stop("SWF files must not contain NUL bytes.", call. = FALSE)
  }

  text <- rawToChar(contents)
  if (!validUTF8(text)) {
    stop("The SWF file is not valid UTF-8: ", path, call. = FALSE)
  }
  Encoding(text) <- "UTF-8"
  lines <- if (nzchar(text)) strsplit(text, "\n", fixed = TRUE)[[1L]] else ""
  lines <- sub("\r$", "", lines)

  if (length(lines) == 0L || !identical(lines[[1L]], "#!swf-v1")) {
    stop("The first line of an SWF file must be exactly '#!swf-v1'.",
         call. = FALSE)
  }
  if (length(lines) == 1L) {
    return(stats::setNames(character(), character()))
  }

  result <- character()
  for (line in lines[-1L]) {
    if (!nzchar(line) || startsWith(line, "#")) {
      next
    }
    if (grepl("\r", line, fixed = TRUE)) {
      stop("SWF values must not contain carriage returns.", call. = FALSE)
    }

    separator <- regexpr("=", line, fixed = TRUE)[[1L]]
    if (separator < 0L) {
      stop("Invalid SWF line (expected 'key=value'): ", line, call. = FALSE)
    }
    key <- substr(line, 1L, separator - 1L)
    value <- substr(line, separator + 1L, nchar(line))
    if (!grepl("^[A-Za-z0-9_.-]+$", key)) {
      stop("Invalid SWF key: ", key, call. = FALSE)
    }
    if (key %in% names(result)) {
      stop("Duplicate SWF key: ", key, call. = FALSE)
    }
    result[[key]] <- value
  }
  result
}

#' @keywords internal
#' @noRd
write_swf <- function(x, path) {
  if (length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("`path` must be a non-empty path of length one.", call. = FALSE)
  }
  if (!(is.atomic(x) || is.list(x))) {
    stop("`x` must be a named atomic vector or list.", call. = FALSE)
  }

  keys <- names(x)
  if (length(x) > 0L &&
      (is.null(keys) || length(keys) != length(x) || anyNA(keys))) {
    stop("Every SWF entry must have a valid name.", call. = FALSE)
  }
  if (length(x) == 0L) {
    keys <- character()
  }
  if (any(!grepl("^[A-Za-z0-9_.-]+$", keys))) {
    stop("SWF keys must match '^[A-Za-z0-9_.-]+$'.", call. = FALSE)
  }
  if (anyDuplicated(keys)) {
    stop("SWF keys must be unique.", call. = FALSE)
  }

  values <- vapply(seq_along(x), function(i) {
    format_swf_value(x[[i]])
  }, character(1L))
  lines <- c("#!swf-v1", paste0(keys, "=", values))

  directory <- dirname(path)
  if (!dir.exists(directory)) {
    stop("The destination directory does not exist: ", directory,
         call. = FALSE)
  }
  temporary <- file.path(
    directory,
    paste0(".", basename(path), ".tmp.", Sys.getpid())
  )
  connection <- file(temporary, open = "wb")
  on.exit({
    close(connection)
    unlink(temporary)
  })
  writeBin(charToRaw(paste0(paste0(lines, collapse = "\n"), "\n")), connection)
  close(connection)
  on.exit(unlink(temporary))

  if (!file.rename(temporary, path)) {
    stop("Could not atomically replace the SWF file: ", path, call. = FALSE)
  }
  invisible(path)
}

#' @keywords internal
#' @noRd
format_swf_value <- function(value) {
  if (length(value) != 1L || is.na(value)) {
    stop("SWF values must be non-missing scalars.", call. = FALSE)
  }
  if (is.numeric(value) && !is.finite(value)) {
    stop("SWF numeric values must be finite.", call. = FALSE)
  }
  if (is.numeric(value)) {
    value <- format(value, scientific = FALSE, trim = TRUE)
  } else {
    value <- as.character(value)
  }
  value <- enc2utf8(value)
  if (grepl("[\r\n]", value)) {
    stop("SWF values must not contain newlines.", call. = FALSE)
  }
  value
}
