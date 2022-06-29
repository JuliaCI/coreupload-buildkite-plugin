#!/bin/bash
set -euo pipefail
shopt -s globstar extglob nullglob
REPO_DIR="$(dirname $( cd -- "$( dirname -- "${BASH_SOURCE[0]:-$0}"; )" &> /dev/null && pwd 2> /dev/null; ) )";

source "${REPO_DIR}/lib/buildkite_support.sh"
source "${REPO_DIR}/lib/compression.sh"

# Read in plugin options from the environment right away
CORE_PATTERN="${BUILDKITE_PLUGIN_COREUPLOAD_CORE_PATTERN:-*.core}"
COMPRESSOR="${BUILDKITE_PLUGIN_COREUPLOAD_COMPRESSOR:-none}"
DEBUGGER_TIMEOUT="${BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER_TIMEOUT:-120}"
DISABLED="${BUILDKITE_PLUGIN_COREUPLOAD_DISABLED:-}"
CREATE_BUNDLE="${BUILDKITE_PLUGIN_COREUPLOAD_CREATE_BUNDLE:-false}"
DEBUG_PLUGIN="${BUILDKITE_PLUGIN_COREUPLOAD_DEBUG_PLUGIN:-false}"



# If someone has requested debugging, enable it from this point out
# Use a custom prompt to avoid nested bash stacks generating '---'
# and fooling buildkite's output chunking algorithm.
if [[ "${DEBUG_PLUGIN}" == "true" ]]; then
    echo "--- coreupload debug output"
    PS4="> "
    set -x
fi

# Determine whether we're using `lldb` or `gdb` as our debugger tool
if [[ ! -v "BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER" ]]; then
    # We prefer `gdb` _only_ because we have seen many freezes with `lldb`.
    if which "gdb" >/dev/null 2>/dev/null; then
        export BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER="gdb"
    elif which "lldb"  >/dev/null 2>/dev/null; then
        export BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER="lldb"
    else
        warn "No debugger found, some coreupload functions unavailable!"
        export BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER=""

        CREATE_BUNDLE="false"
    fi
fi

# Check for compressor tools
ensure_tool "tar" "needed to compress "
if [[ "${COMPRESSOR}" == "zstd" ]]; then
    ensure_tool "zstd" "needed to compress corefiles"
fi

DBG_COMMANDS=()
if [[ "${BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER}" == "lldb" ]]; then
    source "${REPO_DIR}/lib/lldb_support.sh"
    readarray -t DBG_COMMANDS < <(collect_buildkite_array "BUILDKITE_PLUGIN_COREUPLOAD_LLDB_COMMANDS")

    # If the user has accidentally provided `gdb_commands` in their YAML script, but we're using `lldb`,
    # notify them that they need to change their
    if [[ "${#DBG_COMMANDS[@]}" == 0 ]]; then
        readarray -t DBG_COMMANDS < <(collect_buildkite_array "BUILDKITE_PLUGIN_COREUPLOAD_GDB_COMMANDS")
        if [[ "${#DBG_COMMANDS[@]}" > 0 ]]; then
            warn "It appears that you have provided gdb_commands when you should provide lldb_commands!" >&2
        fi
    fi

fi

if [[ "${BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER}" == "gdb" ]]; then
    # We need `file` to figure out what executable goes with a corefile, if we're using `gdb`.
    ensure_tool "file" "needed to parse executable paths out of corefiles!"
    source "${REPO_DIR}/lib/gdb_support.sh"

    readarray -t DBG_COMMANDS < <(collect_buildkite_array "BUILDKITE_PLUGIN_COREUPLOAD_GDB_COMMANDS")
fi

# If someone has requested that we not operate, quit out here:
if [[ -n "${DISABLED}" ]]; then
    exit 0
fi
