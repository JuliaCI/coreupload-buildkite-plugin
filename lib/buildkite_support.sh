#!/bin/bash

# Figure out which shasum program to use
if [[ -n $(which sha256sum 2>/dev/null) ]]; then
    SHASUM="sha256sum"
elif [[ -n $(which shasum 2>/dev/null) ]]; then
    SHASUM="shasum -a 256"
else
    die "No sha256sum/shasum available!"
fi

function job_link() {
    echo -n "${BUILDKITE_BUILD_URL}#${BUILDKITE_JOB_ID}"
}

function buildkite_annotation() {
    if which buildkite-agent >/dev/null 2>/dev/null; then
        # By default, the annotation context is unique to the message and buildkite job
        local CONTEXT=$(echo "${2}" "${BUILDKITE_JOB_ID}" | ${SHASUM})
        if [[ "$#" -gt 2 ]]; then
            CONTEXT="${3}"
        fi
        buildkite-agent annotate --context="${CONTEXT}" --style="${1}" "${2} ([job]($(job_link)))"
    fi
}

# Helper function to kill execution when something goes wrong
function die() {
    echo "ERROR: ${1}" >&2
    buildkite_annotation "error" "$@"
    exit 1
}

function warn() {
    echo "WARN: ${1}" >&2
    buildkite_annotation "warning" "$@"
}

# Helper function to collect a buildkite array
function collect_buildkite_array() {
    local PARAMETER_NAME="${1}"

    local IDX=0
    while [[ -v "${PARAMETER_NAME}_${IDX}" ]]; do
        # Fetch the pattern
        VARNAME="${PARAMETER_NAME}_${IDX}"
        printf "%s\n" "${!VARNAME}"

        IDX=$((${IDX} + 1))
    done
}

# Helper function to collect a glob pattern
function collect_glob_pattern() {
    local target="${1}"
    # Iterate over the glob pattern
    for f in ${target}; do
        # Ignore directories, only list files
        if [[ -f "${f}" ]]; then
            printf "%s\n" "${f}"
        fi
    done
}

# Helper function to assert that a tool is available
function ensure_tool() {
    local TOOL="${1}"
    local REASON="${2}"
    if ! which "${TOOL}" >/dev/null 2>/dev/null; then
        die "Cannot find '${TOOL}', ${REASON}!"
    fi
}

function collapse_dotdot() {
    # Sed command that deletes `..` entries by removing the previous directory entry
    #   "/foo/bin/../lib/../../foo/lib/libfoo.so" -> "/foo/lib/libfoo.so"
    # Note that to be compatible with macOS/BSD sed we are forced to provide the command
    # as a single string with newlines breaking up the commands.
    sed -E ':loop
s&[^/]+/\.\./&&
t loop'
}

# Helper function to filter out only existant files.
# Also deduplicates the files and removes `/../` from the path.
function filter_existant_files() {
    # Read `stdin` into `INPUT_FILES`
    local INPUT_FILES=()
    readarray -t INPUT_FILES

    # Construct associative array, use that to store de-duplicated filenames
    declare -A OUTPUT_FILES=()
    for F in "${INPUT_FILES[@]}"; do
        if [[ -f "${F}" ]]; then
            OUTPUT_FILES["$(collapse_dotdot <<<"${F}")"]=1
        fi
    done

    # Output our list of real files, sorted for cleanliness.  With no files, `printf`
    # would still print one empty line, which `tar` rejects as an empty member name.
    if [[ "${#OUTPUT_FILES[@]}" -gt 0 ]]; then
        printf "%s\n" "${!OUTPUT_FILES[@]}" | sort
    fi
}

# The descendants of process `${1}`, one per line
function descendant_pids() {
    local CHILD
    for CHILD in $(pgrep -P "${1}" || true); do
        echo "${CHILD}"
        descendant_pids "${CHILD}"
    done
}

# Run a command, terminating it and its descendants if it is still running after `${1}`
# seconds.  Returns the command's exit status.
function run_with_timeout() {
    local TIMEOUT="${1}"
    shift

    local FIRED
    FIRED="$(mktemp)"
    rm -f "${FIRED}"

    "$@" &
    local PID="$!"
    # The watchdog's output goes to /dev/null so that a leftover `sleep` cannot keep
    # the hook's output pipe open after we are done.
    (
        set +e
        sleep "${TIMEOUT}"
        touch "${FIRED}"
        # Descendants too: e.g. a hung pipeline inside a function would otherwise keep
        # the hook's output open after the function's subshell is gone.
        PIDS="${PID} $(descendant_pids "${PID}")"
        # shellcheck disable=SC2086 # one PID per word
        kill -TERM ${PIDS}
        for _ in $(seq 10); do
            sleep 1
            # shellcheck disable=SC2086
            kill -0 ${PIDS} || break
        done
        # shellcheck disable=SC2086
        kill -KILL ${PIDS}
    ) >/dev/null 2>&1 &
    local WATCHDOG_PID="$!"

    local STATUS=0
    wait "${PID}" || STATUS="$?"
    if [[ -e "${FIRED}" ]]; then
        # Let the watchdog finish off descendants that survive the command
        wait "${WATCHDOG_PID}" || true
        echo "Killed '${1}' after ${TIMEOUT} seconds" >&2
        rm -f "${FIRED}"
    else
        # Stop the watchdog before its `sleep`: a watchdog whose `sleep` dies first
        # would go on to kill whatever process now has PID.
        local WATCHDOG_CHILDREN
        WATCHDOG_CHILDREN="$(pgrep -P "${WATCHDOG_PID}" || true)"
        kill "${WATCHDOG_PID}" 2>/dev/null || true
        wait "${WATCHDOG_PID}" 2>/dev/null || true
        # shellcheck disable=SC2086
        kill ${WATCHDOG_CHILDREN} 2>/dev/null || true
        rm -f "${FIRED}"
    fi
    return "${STATUS}"
}

# Free space, in KiB, on the filesystem holding `${1}`
function free_space_kib() {
    df -Pk "${1}" | awk 'NR == 2 { print $4 }'
}

# Size of a file, in KiB
function file_size_kib() {
    local SIZE
    # GNU stat first: on Linux, `stat -f` means `--file-system` and also succeeds
    SIZE="$(stat -c %s "${1}" 2>/dev/null || stat -f %z "${1}")"
    echo "$(( SIZE / 1024 ))"
}
