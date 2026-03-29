# Replace a Line in a File With New Lines

This function is used to complete the templates provided by the package
with the user provided informations

## Usage

``` r
simple_brew(file_in, placeholder_line, replacement_lines, file_out = NULL)
```

## Arguments

- file_in:

  the file to read from

- placeholder_line:

  the line to replace

- replacement_lines:

  a character vector of lines to insert into the file

- file_out:

  path to the new file (default to "file_in" if missing)

## Value

path to the output file (invisibly)
