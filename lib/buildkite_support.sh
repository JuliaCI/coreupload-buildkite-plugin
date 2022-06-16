#!/bin/bash

# Figure out which shasum program to use
if [[ -n $(which sha256sum 2>/dev/null) ]]; then
    SHASUM="sha256sum"
elif [[ -n $(which shasum 2>/dev/null) ]]; then
    SHASUM="shasum -a 256"
else
    die "No sha256sum/shasum available!"
fi

# Helper function to kill execution when something goes wrong
function die() {
    echo "ERROR: ${1}" >&2
    if which buildkite-agent >/dev/null 2>/dev/null; then
        # By default, the annotation context is unique to the message
        local CONTEXT=$(echo "${1}" | ${SHASUM})
        if [[ "$#" -gt 1 ]]; then
            CONTEXT="${2}"
        fi
        buildkite-agent annotate --context="${CONTEXT}" --style=error "${1}"
    fi
    exit 1
}

function warn() {
    echo "WARN: ${1}" >&2
    if which buildkite-agent >/dev/null 2>/dev/null; then
        # By default, the annotation context is unique to the message
        local CONTEXT=$(echo "${1}" | ${SHASUM})
        if [[ "$#" -gt 1 ]]; then
            CONTEXT="${2}"
        fi
        buildkite-agent annotate --context="${CONTEXT}" --style=warning "${1}"
    fi
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
    declare -A OUTPUT_FILES
    for F in "${INPUT_FILES[@]}"; do
        if [[ -f "${F}" ]]; then
            OUTPUT_FILES["$(collapse_dotdot <<<"${F}")"]=1
        fi
    done

    # Output our list of real files, sorted for cleanliness
    printf "%s\n" "${!OUTPUT_FILES[@]}" | sort
}
