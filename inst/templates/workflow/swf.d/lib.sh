#!/bin/bash
# Shared, non-executable helpers for the slurmworkflow engine.

# .swf files are data, never shell code. Keep that rule even for files whose
# names look trustworthy: users may write messages by hand.
declare -A SWF_VALUES=()
SWF_KEYS=()

function swf_now {
  date '+%Y-%m-%dT%H:%M:%S'
}

function swf_error {
  printf 'swf: %s\n' "$*" >&2
}

# swf_read reports its error on stderr and keeps it in SWF_READ_ERROR, so that
# `swf check` can list it.
SWF_READ_ERROR=''
function swf_read_error {
  SWF_READ_ERROR="$*"
  swf_error "$*"
}

# Read one .swf file into SWF_KEYS and SWF_VALUES. SWF_KEYS preserves order;
# the associative array is only an index into the values.
function swf_read {
  local path="$1"
  local line key value
  local line_number=0

  SWF_KEYS=()
  SWF_VALUES=()
  SWF_READ_ERROR=''

  if [[ ! -f "$path" ]]; then
    swf_read_error "file not found: $path"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"

    if (( line_number == 1 )); then
      if [[ "$line" != '#!swf-v1' ]]; then
        swf_read_error "$path: line 1 must be #!swf-v1"
        return 1
      fi
      continue
    fi

    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      swf_read_error "$path:$line_number: expected key=value"
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      swf_read_error "$path:$line_number: invalid key: $key"
      return 1
    fi
    if [[ ${SWF_VALUES[$key]+present} ]]; then
      swf_read_error "$path:$line_number: duplicate key: $key"
      return 1
    fi

    SWF_KEYS+=("$key")
    SWF_VALUES[$key]="$value"
  done < "$path"

  if (( line_number == 0 )); then
    swf_read_error "$path: empty file (missing #!swf-v1)"
    return 1
  fi
}

# Set STEP_DIR, STEP_N, STEP_NAME and STEP_ID. Names are the canonical runtime
# references. A third argument of "number" also permits an exact numeric N.
function swf_resolve_step {
  local root="$1"
  local reference="$2"
  local allow_number="${3:-}"
  local dir base number name matches=0

  STEP_DIR=''
  STEP_N=''
  STEP_NAME=''
  STEP_ID=''

  if [[ "$allow_number" == number && "$reference" =~ ^[0-9]+$ ]]; then
    :
  elif [[ "$allow_number" == id && "$reference" =~ ^[1-9][0-9]*_[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    :
  elif [[ ! "$reference" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    return 1
  fi

  for dir in "$root"/swf.d/steps/*/; do
    [[ -d "$dir" ]] || continue
    base="${dir%/}"
    base="${base##*/}"
    [[ "$base" == *_* ]] || continue
    number="${base%%_*}"
    name="${base#*_}"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || continue

    if [[ "$allow_number" == number && "$reference" =~ ^[0-9]+$ ]]; then
      [[ "$number" == "$reference" ]] || continue
    elif [[ "$allow_number" == id ]]; then
      [[ "$base" == "$reference" ]] || continue
    else
      [[ "$name" == "$reference" ]] || continue
    fi

    matches=$((matches + 1))
    STEP_DIR="${dir%/}"
    STEP_N="$number"
    STEP_NAME="$name"
    STEP_ID="${number}_${name}"
  done

  [[ "$matches" == 1 ]]
}

function swf_step_count {
  local root="$1"
  local dir base number name
  local count=0
  for dir in "$root"/swf.d/steps/*/; do
    [[ -d "$dir" ]] || continue
    base="${dir%/}"
    base="${base##*/}"
    [[ "$base" == *_* ]] || continue
    number="${base%%_*}"
    name="${base#*_}"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# Global lock directory and ownership flag. Callers normally install an EXIT
# trap immediately after a successful lock.
SWF_LOCK_DIR=''
SWF_LOCK_HELD=0

function swf_lock {
  local run_dir="$1"
  local attempt timeout owner
  timeout="${SWF_LOCK_TIMEOUT:-60}"
  if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    swf_error "SWF_LOCK_TIMEOUT must be a non-negative integer"
    return 1
  fi
  SWF_LOCK_DIR="$run_dir/lock"
  for (( attempt = 0; attempt <= timeout * 5; attempt++ )); do
    if mkdir "$SWF_LOCK_DIR" 2>/dev/null; then
      SWF_LOCK_HELD=1
      if ! printf 'pid=%s host=%s\n' "$$" "$(hostname)" > "$SWF_LOCK_DIR/owner"; then
        swf_unlock
        swf_error "could not write lock owner: $SWF_LOCK_DIR/owner"
        return 1
      fi
      trap "${SWF_EXIT_TRAP:-swf_unlock}" EXIT
      return 0
    fi
    (( attempt < timeout * 5 )) && sleep 0.2
  done
  owner='unknown'
  [[ -f "$SWF_LOCK_DIR/owner" ]] && owner="$(< "$SWF_LOCK_DIR/owner")"
  swf_error "lock $SWF_LOCK_DIR held for $timeout s: a job may have been killed while holding it; if no job of this run is running, remove it"
  swf_error "lock owner: $owner"
  return 1
}

function swf_unlock {
  if [[ "$SWF_LOCK_HELD" == 1 ]]; then
    rm -f "$SWF_LOCK_DIR/owner"
    rmdir "$SWF_LOCK_DIR" 2>/dev/null || true
    SWF_LOCK_HELD=0
  fi
}

function swf_history {
  local run_dir="$1"
  local event="$2"
  shift 2
  {
    printf 'time=%s event=%s' "$(swf_now)" "$event"
    printf ' %s' "$@"
    printf '\n'
  } >> "$run_dir/history"
}

function swf_origin_job {
  if [[ -n "${SLURM_ARRAY_JOB_ID:-}" && -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    printf '%s_%s\n' "$SLURM_ARRAY_JOB_ID" "$SLURM_ARRAY_TASK_ID"
  else
    printf '%s\n' "${SLURM_JOB_ID:-}"
  fi
}

function swf_value_has_newline {
  [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]
}

function swf_word_in_list {
  local wanted="$1"
  local list="$2"
  local word
  for word in $list; do
    [[ "$word" == "$wanted" ]] && return 0
  done
  return 1
}

function swf_atomic_write_current {
  local path="$1"
  local stop_time="$2"
  local key
  local dir tmp
  dir="${path%/*}"
  tmp="$dir/.current.swf.tmp.$$"
  {
    printf '#!swf-v1\n'
    for key in "${SWF_KEYS[@]}"; do
      [[ "$key" == stopped ]] && continue
      printf '%s=%s\n' "$key" "${SWF_VALUES[$key]}"
    done
    printf 'stopped=%s\n' "$stop_time"
  } > "$tmp" || return 1
  mv "$tmp" "$path"
}

# Text files copied from Windows may have CRLF endings. Only the files the
# engine reads are converted: swf, swf.d/*.sh, the .swf files under swf.d
# (run state excluded) and the steps' instructions.sh. User data is left alone.
function fix_crlf_files {
  local root="$1"
  local file
  while IFS= read -r -d '' file; do
    if grep -Iq $'\r' "$file"; then
      sed -i 's/\r$//' "$file"
    fi
  done < <(
    for file in "$root/swf" "$root"/swf.d/*.sh "$root"/swf.d/steps/*/instructions.sh; do
      [[ -f "$file" ]] && printf '%s\0' "$file"
    done
    find "$root/swf.d" -path "$root/swf.d/run" -prune -o -type f -name '*.swf' -print0
  )
}

# Read swf.d/sbatch_rules.swf into RULE_KEYS and RULE_VALUES.
declare -A RULE_VALUES=()
RULE_KEYS=()
function swf_load_rules {
  local root="$1" key
  RULE_KEYS=()
  RULE_VALUES=()
  swf_read "$root/swf.d/sbatch_rules.swf" || return 1
  for key in "${SWF_KEYS[@]}"; do
    RULE_KEYS+=("$key")
    RULE_VALUES[$key]="${SWF_VALUES[$key]}"
  done
  if [[ ! ${RULE_VALUES[valid]+present} ]]; then
    swf_read_error "$root/swf.d/sbatch_rules.swf: no valid key"
    return 1
  fi
}

# Check the engine keys of the file last read by swf_read against the rules
# loaded by swf_load_rules: every opt.<name> has a valid, non-reserved name and
# a non-empty value; skip and repeat are 0 or 1; on_failure is stop or
# continue. Each problem is appended to SWF_KEY_PROBLEMS as "<key>: <why>";
# SWF_INVALID_KEY is the first offending key. Returns 1 on any problem.
SWF_KEY_PROBLEMS=()
SWF_INVALID_KEY=''
function swf_validate_keys {
  local key option value why
  SWF_KEY_PROBLEMS=()
  SWF_INVALID_KEY=''
  for key in ${SWF_KEYS[@]+"${SWF_KEYS[@]}"}; do
    value="${SWF_VALUES[$key]}"
    why=''
    case "$key" in
      opt.*)
        option="${key#opt.}"
        if [[ -z "$option" ]]; then
          why='empty option name'
        elif ! swf_word_in_list "$option" "${RULE_VALUES[valid]:-}"; then
          why="invalid sbatch option: $option"
        elif swf_word_in_list "$option" "${RULE_VALUES[reserved]:-}"; then
          why="reserved sbatch option: $option"
        elif [[ -z "$value" ]]; then
          why='empty value'
        fi
        ;;
      skip|repeat)
        [[ "$value" == 0 || "$value" == 1 ]] || why="must be 0 or 1, not '$value'"
        ;;
      on_failure)
        [[ "$value" == stop || "$value" == continue ]] || why="must be stop or continue, not '$value'"
        ;;
    esac
    if [[ -n "$why" ]]; then
      SWF_KEY_PROBLEMS+=("$key: $why")
      [[ -n "$SWF_INVALID_KEY" ]] || SWF_INVALID_KEY="$key"
    fi
  done
  (( ${#SWF_KEY_PROBLEMS[@]} == 0 ))
}

# History fields are space-separated: encode %, spaces and tabs in values.
function swf_history_value {
  local value="$1"
  value="${value//%/%25}"
  value="${value// /%20}"
  value="${value//$'\t'/%09}"
  printf '%s' "$value"
}
