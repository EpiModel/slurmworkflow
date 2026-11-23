#!/bin/bash
#SBATCH --export=NONE
#SBATCH --open-mode=append

# Refuse old bash first, with syntax that bash 3.2 (stock macOS) can parse.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  printf 'swf: bash >= 4.2 is required (found %s)\n' "${BASH_VERSION%%[!0-9.]*}" >&2
  exit 2
fi

# Every non-zero exit of this script goes through swf_fail, which writes the
# failed/<id> marker read by the next controller: payload errors, signals
# (time limit, scancel) and pre-flight errors alike.

SWF_RUN_DIR=''
SWF__FAILED_DONE=0
SWF__PAYLOAD_PID=''
if [[ -n "${SLURM_ARRAY_JOB_ID:-}" && -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  SWF__FAILED_ID="${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
else
  SWF__FAILED_ID="${SLURM_JOB_ID:-unknown}"
fi

# Write failed/<id> atomically (once) when the run directory exists, then exit.
function swf_fail {
  local code="$1" dir tmp
  if [[ ! "$code" =~ ^[0-9]+$ ]] || (( code == 0 )); then code=1; fi
  if (( ! SWF__FAILED_DONE )) && [[ -n "$SWF_RUN_DIR" && -d "$SWF_RUN_DIR" ]]; then
    dir="$SWF_RUN_DIR/failed"
    mkdir -p "$dir" 2>/dev/null
    tmp="$dir/.${SWF__FAILED_ID}.tmp.$$"
    if printf '%s\n' "$code" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$SWF__FAILED_ID"; then
      SWF__FAILED_DONE=1
    else
      rm -f "$tmp" 2>/dev/null
      printf 'swf: could not write failure marker %s\n' "$dir/$SWF__FAILED_ID" >&2
    fi
  fi
  exit "$code"
}

function swf_preflight_error {
  printf 'swf: %s\n' "$*" >&2
  swf_fail 1
}

# Slurm signals the job on a time limit or scancel. Forward the signal to the
# payload (and to this job's process group when this script leads it), record
# the failure, and exit with 128 + the signal number.
function swf_on_signal {
  local name="$1" number="$2" forward="$1" pgid
  trap '' TERM INT HUP
  # Background children of a non-interactive shell ignore INT: send TERM.
  [[ "$name" == INT ]] && forward=TERM
  if [[ -n "$SWF__PAYLOAD_PID" ]]; then
    kill -s "$forward" "$SWF__PAYLOAD_PID" 2>/dev/null
    pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    if [[ "$pgid" == "$$" ]]; then
      kill -s "$forward" -- "-$pgid" 2>/dev/null
    fi
  fi
  printf 'swf: job %s received SIG%s; payload stopped\n' "$SWF__FAILED_ID" "$name" >&2
  if [[ -n "$SWF__START_MS" ]]; then
    # The payload is not reaped yet: its CPU time is unknown.
    swf_time_table "SIG$name" "$(swf_duration $(( $(swf_now_ms) - SWF__START_MS )))" '?' '?' '?'
  fi
  [[ -z "$SWF__TIMES_FILE" ]] || rm -f "$SWF__TIMES_FILE"
  swf_fail $((128 + number))
}
trap 'swf_on_signal TERM 15' TERM
trap 'swf_on_signal INT 2' INT
trap 'swf_on_signal HUP 1' HUP

# Wall clock in milliseconds: GNU date, else whole seconds from $SECONDS.
function swf_now_ms {
  local ns
  ns="$(date +%s%N 2>/dev/null)"
  if [[ "$ns" =~ ^[0-9]{10,}$ ]]; then
    printf '%s\n' $(( ${ns:0:${#ns}-6} ))
  else
    printf '%s\n' $(( SECONDS * 1000 ))
  fi
}

# Milliseconds as 12.345s below a minute, else 1h02m03s / 4m05s.
function swf_duration {
  local ms="$1" s h m
  (( ms >= 0 )) || ms=0
  if (( ms < 60000 )); then
    printf '%d.%03ds' $(( ms / 1000 )) $(( ms % 1000 ))
    return
  fi
  s=$(( (ms + 500) / 1000 )); h=$(( s / 3600 )); m=$(( s % 3600 / 60 )); s=$(( s % 60 ))
  if (( h > 0 )); then printf '%dh%02dm%02ds' "$h" "$m" "$s"; else printf '%dm%02ds' "$m" "$s"; fi
}

# `times` duration (1m2.345s) to milliseconds.
function swf_times_ms {
  local value="$1" minutes seconds whole frac
  [[ "$value" =~ ^([0-9]+)m([0-9]+)(\.([0-9]+))?s$ ]] || { printf '\n'; return; }
  minutes="${BASH_REMATCH[1]}"; whole="${BASH_REMATCH[2]}"; frac="${BASH_REMATCH[4]}000"
  printf '%s\n' $(( 10#$minutes * 60000 + 10#$whole * 1000 + 10#${frac:0:3} ))
}

# Last log line, like R's system.time: elapsed, then the user and system CPU
# time of the reaped children (the payload and what it waited for).
# `times` must run in this shell (a subshell starts with no child time), so it
# writes to a file; sets SWF__CHILD_USER and SWF__CHILD_SYS in milliseconds.
SWF__TIMES_FILE=''
function swf_child_times {
  local line=''
  SWF__CHILD_USER='' SWF__CHILD_SYS=''
  [[ -n "$SWF__TIMES_FILE" ]] || return 0
  times > "$SWF__TIMES_FILE" 2>/dev/null || return 0
  { read -r line; read -r line; } < "$SWF__TIMES_FILE" || return 0
  SWF__CHILD_USER="$(swf_times_ms "${line%% *}")"
  SWF__CHILD_SYS="$(swf_times_ms "${line##* }")"
}

# Two log lines, a header and the values, each column as wide as its widest
# cell:
#   swf: exit  elapsed   user      system  cpus  used
#   swf: 0     1h00m12s  7h55m40s  0m30s   8     99%
function swf_time_table {
  local -a head=(exit elapsed user system cpus used)
  local -a vals=("$1" "$2" "$3" "$4" "$SWF__CPUS" "$5")
  local i width line1='swf:' line2='swf:'
  for i in "${!head[@]}"; do
    width=${#head[i]}
    (( ${#vals[i]} <= width )) || width=${#vals[i]}
    if (( i < ${#head[@]} - 1 )); then
      line1+="$(printf ' %-*s ' "$width" "${head[i]}")"
      line2+="$(printf ' %-*s ' "$width" "${vals[i]}")"
    else
      line1+=" ${head[i]}"
      line2+=" ${vals[i]}"
    fi
  done
  printf '%s\n%s\n' "$line1" "$line2" >&2
}

# Like R's system.time: elapsed, then the user and system CPU time of the
# reaped children (the payload and what it waited for), summed over processes.
function swf_report_time {
  local status="$1" elapsed user='?' sys='?' used='?'
  elapsed=$(( $(swf_now_ms) - SWF__START_MS ))
  swf_child_times
  rm -f "$SWF__TIMES_FILE"
  if [[ -n "$SWF__CHILD_USER" && -n "$SWF__CHILD_SYS" && -n "$SWF__BASE_USER" && -n "$SWF__BASE_SYS" ]]; then
    user=$(( SWF__CHILD_USER - SWF__BASE_USER ))
    sys=$(( SWF__CHILD_SYS - SWF__BASE_SYS ))
    if [[ "$SWF__CPUS" =~ ^[1-9][0-9]*$ ]] && (( elapsed > 0 )); then
      used="$(( (user + sys) * 100 / (elapsed * SWF__CPUS) ))%"
    fi
    user="$(swf_duration "$user")"
    sys="$(swf_duration "$sys")"
  fi
  swf_time_table "$status" "$(swf_duration "$elapsed")" "$user" "$sys" "$used"
}

SWF__START_MS=''
SWF__CPUS="${SLURM_CPUS_ON_NODE:-$(nproc 2>/dev/null || printf '?')}"

# First log line: where the job runs and the CPUs Slurm gave it on that node.
printf 'swf: job %s on node %s with %s cpu(s)\n' "$SWF__FAILED_ID" \
  "${SLURMD_NODENAME:-$(hostname 2>/dev/null || printf '?')}" "$SWF__CPUS" >&2

if (( $# >= 2 )); then
  SWF_RUN_DIR="$1/swf.d/run/$2"
fi
if (( $# != 4 )); then
  swf_preflight_error 'usage: job.sh <root> <run_id> <N>_<name> <submission>'
fi

SWF_ROOT="$(realpath "$1")" || swf_preflight_error "workflow root not found: $1"
SWF_RUN_ID="$2"
SWF_STEP_ID="$3"
SWF_RUN_DIR="$SWF_ROOT/swf.d/run/$SWF_RUN_ID"

[[ -f "$SWF_ROOT/swf.d/lib.sh" ]] || swf_preflight_error "engine library not found: $SWF_ROOT/swf.d/lib.sh"
source "$SWF_ROOT/swf.d/lib.sh" || swf_preflight_error 'could not load swf.d/lib.sh'

if [[ ! -d "$SWF_RUN_DIR" ]]; then
  swf_preflight_error "run directory not found: $SWF_RUN_DIR"
fi
if [[ ! -f "$4" ]]; then
  swf_preflight_error "submission not found: $4"
fi
SWF_SUBMISSION="$(realpath "$4")" || swf_preflight_error "submission not found: $4"
if ! swf_resolve_step "$SWF_ROOT" "$SWF_STEP_ID" id; then
  swf_preflight_error "unknown step: $SWF_STEP_ID"
fi

export SWF_ROOT
export SWF__DIR="$SWF_ROOT/swf.d"
export SWF_NAME="$(basename "$SWF_ROOT")"
export SWF_RUN_ID
export SWF_RUN_DIR
export SWF_LOG_DIR="$SWF_ROOT/log/$SWF_RUN_ID"
export SWF_CMD="$SWF_ROOT/swf"
export SWF_CUR="$STEP_N"
export SWF_CUR_NAME="$STEP_NAME"
export SWF__CUR_DIR="$STEP_DIR"
export SWF__INSTRUCTIONS_SCRIPT="$STEP_DIR/instructions.sh"
export SWF_SUBMISSION

if [[ ! -f "$SWF__INSTRUCTIONS_SCRIPT" ]]; then
  swf_preflight_error "instructions not found: $SWF__INSTRUCTIONS_SCRIPT"
fi

# Run the payload in the background so that a trapped signal interrupts
# `wait` at once (bash defers traps while a foreground child runs). Keep the
# job's standard input instead of the /dev/null given to background commands.
# Child CPU time so far (date, hostname...), subtracted after the payload.
SWF__TIMES_FILE="$(mktemp "${TMPDIR:-/tmp}/swf-times.XXXXXX" 2>/dev/null)" || SWF__TIMES_FILE=''
swf_child_times
SWF__BASE_USER="$SWF__CHILD_USER" SWF__BASE_SYS="$SWF__CHILD_SYS"
SWF__START_MS="$(swf_now_ms)"
bash -e "$SWF__INSTRUCTIONS_SCRIPT" 0<&0 &
SWF__PAYLOAD_PID=$!
wait "$SWF__PAYLOAD_PID"
STATUS=$?
SWF__PAYLOAD_PID=''
swf_report_time "$STATUS"
if (( STATUS != 0 )); then
  swf_fail "$STATUS"
fi
exit 0
