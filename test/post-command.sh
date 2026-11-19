#!/usr/bin/env bash
# Run hooks/post-command against fake cores, with doubles for lldb, buildkite-agent and df.
# Usage: bash test/post-command.sh
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"

cat > "${TMP}/bin/lldb" <<'LLDB'
#!/usr/bin/env bash
# Called as: lldb -x [--file EXE] -c CORE --batch -o CMD -Q
EXE="" CORE="" CMD=""
while (( $# )); do
    case "$1" in
        --file) EXE="$2"; shift ;;
        -c) CORE="$2"; shift ;;
        -o) CMD="$2"; shift ;;
    esac
    shift
done
if [[ -n "${WANT_EXE:-}" && "${EXE}" != "${PWD}/${WANT_EXE}" ]]; then
    echo "lldb got executable '${EXE}' for ${CORE}" >> "${LOG}.badexe"
fi
case "${CMD}" in
    "image list") if [[ -n "${NO_IMAGES:-}" ]]; then exit 1; fi
                  echo "[  0] ABCD 0x0000000100000000 ${PWD}/fake-exe (0x0)" ;;
    *) if [[ "${CORE}" == "${HANG_CORE:-}" ]]; then sleep 1000; fi
       echo "${CORE}" >> "${LOG}.debugged" ;;
esac
LLDB
# For FREEBSD=1: the executable that FreeBSD's procstat reads from a core
cat > "${TMP}/bin/procstat" <<'PROCSTAT'
#!/usr/bin/env bash
[[ "$1" == -b ]] || exit 1
echo "  PID COMM                OSREL PATH"
echo " 1245 julia             1404000 ${PWD}/fake exe"
PROCSTAT
cat > "${TMP}/bin/uname" <<'UNAME'
#!/usr/bin/env bash
if [[ -n "${FREEBSD:-}" ]]; then echo FreeBSD; else echo Linux; fi
UNAME
cat > "${TMP}/bin/buildkite-agent" <<'AGENT'
#!/usr/bin/env bash
echo "$3" >> "${LOG}.uploaded"
zstd -dc "$3" | wc -c | tr -d ' ' >> "${LOG}.sizes"
if [[ -n "${HANG_UPLOAD:-}" ]]; then sleep 1000; fi
AGENT
cat > "${TMP}/bin/df" <<'DF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk1 1000000000 0 ${FREE_KIB:-1000000000} 1% /"
DF
chmod +x "${TMP}/bin/"*

FAILURES=0
# run NAME EXPECTED_DEBUGGED EXPECTED_UPLOADED [VAR=VALUE...]
function run() {
    local NAME="$1" DEBUGGED="$2" UPLOADED="$3"
    shift 3
    local WORK="${TMP}/${NAME}"
    mkdir -p "${WORK}/test"
    echo exe > "${WORK}/fake-exe"
    echo exe > "${WORK}/fake exe"
    # Name order differs from age order
    local I
    for I in 1 2 3; do
        head -c 100000 /dev/urandom > "${WORK}/test/julia-pid${I}.core"
        touch -t "20261107070${I}" "${WORK}/test/julia-pid${I}.core"
    done
    touch -t 202611070700 "${WORK}/test/julia-pid3.core"
    local WRITER=""
    if [[ " $* " == *" GROW=1 "* ]]; then
        # Still being written when the hook starts
        (for I in 1 2 3 4; do sleep 0.5; head -c 100000 /dev/urandom >> "${WORK}/test/julia-pid1.core"; done) &
        WRITER=$!
    fi
    (cd "${WORK}" && env PATH="${TMP}/bin:${PATH}" LOG="${WORK}/log" \
        BUILDKITE_PLUGIN_COREUPLOAD_CORE_PATTERN='**/*.core' \
        BUILDKITE_PLUGIN_COREUPLOAD_COMPRESSOR=zstd \
        BUILDKITE_PLUGIN_COREUPLOAD_CREATE_BUNDLE=true \
        BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER=lldb \
        BUILDKITE_PLUGIN_COREUPLOAD_LLDB_COMMANDS_0="bt all" \
        "$@" timeout 60 bash "${REPO_DIR}/hooks/post-command" > "${WORK}/output" 2>&1) || true
    if [[ -n "${WRITER}" ]]; then wait "${WRITER}" || true; fi
    local GOT_DEBUGGED GOT_UPLOADED LEFT
    touch "${WORK}/log.debugged" "${WORK}/log.uploaded" "${WORK}/log.sizes" "${WORK}/log.badexe"
    GOT_DEBUGGED="$(sed 's|.*/||' "${WORK}/log.debugged" | tr '
' ' ')"
    GOT_UPLOADED="$(sed 's|.*/||' "${WORK}/log.uploaded" | tr '
' ' ')"
    LEFT="$(find "${WORK}/test" -name '*.core*' | wc -l | tr -d ' ')"
    # The bundle of a growing core must hold all of it
    local MIN_SIZE=0
    if [[ " $* " == *" GROW=1 "* ]]; then MIN_SIZE=500000; fi
    local GOT_SIZE
    GOT_SIZE="$(sort -n "${WORK}/log.sizes" | tail -1)"
    if [[ "${GOT_DEBUGGED}" == "${DEBUGGED}" && "${GOT_UPLOADED}" == "${UPLOADED}" && "${LEFT}" == 0 \
          && "${GOT_SIZE:-0}" -ge "${MIN_SIZE}" && ! -s "${WORK}/log.badexe" ]]; then
        echo "ok   ${NAME}"
    else
        echo "FAIL ${NAME}: debugged '${GOT_DEBUGGED}' (want '${DEBUGGED}'), uploaded '${GOT_UPLOADED}' (want '${UPLOADED}'), ${LEFT} files left, largest bundle ${GOT_SIZE:-0} bytes (want >= ${MIN_SIZE})"
        sed 's/^/     | /' "${WORK}/output" "${WORK}/log.badexe"
        FAILURES=$(( FAILURES + 1 ))
    fi
}

# timeout_case NAME MAX_SECONDS SCRIPT: SCRIPT, run with lib/buildkite_support.sh loaded, must
# finish and close its output within MAX_SECONDS, and say "Killed" (from run_with_timeout).
function timeout_case() {
    local NAME="$1" MAX="$2" SCRIPT="$3" START OUTPUT
    START="$(date +%s)"
    OUTPUT="$(timeout 60 bash -c "set -euo pipefail; source '${REPO_DIR}/lib/buildkite_support.sh'; ${SCRIPT}" 2>&1 || true)"
    if (( $(date +%s) - START <= MAX )) && [[ "${OUTPUT}" == *Killed* ]]; then
        echo "ok   ${NAME}"
    else
        echo "FAIL ${NAME}: took $(( $(date +%s) - START )) s (max ${MAX}), output: ${OUTPUT}"
        FAILURES=$(( FAILURES + 1 ))
    fi
}

# Not in a condition: errexit must not stop the watchdog
timeout_case childless 3 'run_with_timeout 1 sleep 30'
# shellcheck disable=SC2016 # expanded by the inner bash
timeout_case grandchildren 3 'f() { local X; X="$(sleep 30 | cat)"; }; run_with_timeout 1 f || true'
timeout_case term_ignored 15 'f() { bash -c "trap \"\" TERM; sleep 30"; }; run_with_timeout 1 f || true'
OUTPUT="$(bash -c "set -euo pipefail; source '${REPO_DIR}/lib/buildkite_support.sh'; for I in \$(seq 100); do run_with_timeout 60 true; done" 2>&1)"
if [[ -z "${OUTPUT}" ]]; then echo "ok   no_timeout"; else echo "FAIL no_timeout: ${OUTPUT}"; FAILURES=$(( FAILURES + 1 )); fi
# Windows has no `pgrep`; the watchdog's `sleep` must not outlive it there either. A
# `sleep` double records its PID once it runs, and the command only returns then.
mkdir -p "${TMP}/nopgrep"
printf '#!/bin/sh\nexit 127\n' > "${TMP}/nopgrep/pgrep"
cat > "${TMP}/nopgrep/sleep" <<SLEEP
#!/bin/sh
if [ "\$1" = 97 ]; then echo \$\$ > "${TMP}/nopgrep/pid.tmp"; mv "${TMP}/nopgrep/pid.tmp" "${TMP}/nopgrep/pid"; fi
exec $(command -v sleep) "\$@"
SLEEP
chmod +x "${TMP}/nopgrep/pgrep" "${TMP}/nopgrep/sleep"
# shellcheck disable=SC2016 # expanded by the inner bash
PATH="${TMP}/nopgrep:${PATH}" bash -c "set -euo pipefail; source '${REPO_DIR}/lib/buildkite_support.sh'
    f() { until [[ -s '${TMP}/nopgrep/pid' ]]; do sleep 0.01; done; }
    run_with_timeout 97 f"
SLEEP_PID="$(cat "${TMP}/nopgrep/pid")"
if ! kill -0 "${SLEEP_PID}" 2>/dev/null; then
    echo "ok   no_pgrep"
else
    echo "FAIL no_pgrep: the watchdog left its sleep (PID ${SLEEP_PID}) behind"; FAILURES=$(( FAILURES + 1 ))
    kill "${SLEEP_PID}"
fi
# Stopped before its `sleep` has started, the watchdog must not signal the command's PID,
# which is no longer the command's by then. `trap` and `kill` are wrapped to hold the
# watchdog right after it set its trap, and to log what it signals.
# shellcheck disable=SC2016 # expanded by the inner bash
OUTPUT="$(bash -c "set -euo pipefail; source '${REPO_DIR}/lib/buildkite_support.sh'
    kill() { echo \"kill \$*\" >> '${TMP}/early.kills'; builtin kill \"\$@\"; }
    trap() {
        builtin trap \"\$@\"
        if [[ \"\$#\" == 2 && \"\$1\" != - && \"\$2\" == TERM ]]; then
            touch '${TMP}/early.armed'
            while :; do sleep 0.01; done
        fi
    }
    f() {
        echo \"\${BASHPID}\" > '${TMP}/early.cmd'
        for _ in \$(seq 1000); do [[ -e '${TMP}/early.armed' ]] && return; sleep 0.01; done
    }
    run_with_timeout 97 f" 2>&1)"
CMD_PID="$(cat "${TMP}/early.cmd")"
if [[ ! -e "${TMP}/early.armed" ]]; then
    echo "FAIL early_term: the watchdog set no TERM trap"; FAILURES=$(( FAILURES + 1 ))
elif grep -qw -- "${CMD_PID}" "${TMP}/early.kills"; then
    echo "FAIL early_term: the watchdog signalled the command's PID ${CMD_PID}"; FAILURES=$(( FAILURES + 1 ))
    sed 's/^/     | /' "${TMP}/early.kills"
elif [[ -n "${OUTPUT}" ]]; then
    echo "FAIL early_term: ${OUTPUT}"; FAILURES=$(( FAILURES + 1 ))
else
    echo "ok   early_term"
fi
if OUTPUT="$(bash -c "set -euo pipefail; source '${REPO_DIR}/lib/buildkite_support.sh'; filter_existant_files </dev/null; echo /nonexistent | filter_existant_files; echo end" 2>&1)" \
        && [[ "${OUTPUT}" == end ]]; then
    echo "ok   no_files"
else
    echo "FAIL no_files: ${OUTPUT}"; FAILURES=$(( FAILURES + 1 ))
fi

# A core that grows by less than 1 KiB at a time
SLOW="${TMP}/slow.core"
: > "${SLOW}"
(for I in $(seq 8); do sleep 0.5; printf x >> "${SLOW}"; done) &
WRITER=$!
bash -c "set -euo pipefail; source '${REPO_DIR}/lib/buildkite_support.sh'; wait_until_unchanged 30 '${SLOW}'" || true
if kill -0 "${WRITER}" 2>/dev/null; then
    echo "FAIL slow_growth: stopped waiting while the core was growing"; FAILURES=$(( FAILURES + 1 ))
else
    echo "ok   slow_growth"
fi
wait "${WRITER}" || true

P=julia-pid
run defaults "${P}3.core ${P}1.core ${P}2.core " "${P}3.core.tar.zst "
run max_cores "${P}3.core ${P}1.core " "${P}3.core.tar.zst " BUILDKITE_PLUGIN_COREUPLOAD_MAX_CORES=2
run max_uploads "${P}3.core ${P}1.core ${P}2.core " "${P}3.core.tar.zst ${P}1.core.tar.zst " \
    BUILDKITE_PLUGIN_COREUPLOAD_MAX_UPLOADS=2
run host_override "${P}3.core ${P}1.core ${P}2.core " "" \
    BUILDKITE_PLUGIN_COREUPLOAD_MAX_UPLOADS=2 COREUPLOAD_MAX_UPLOADS=0
run debugger_hang "${P}3.core ${P}2.core " "${P}3.core.tar.zst " \
    HANG_CORE=test/${P}1.core BUILDKITE_PLUGIN_COREUPLOAD_DEBUGGER_TIMEOUT=1
run upload_hang "${P}3.core ${P}1.core ${P}2.core " "${P}3.core.tar.zst " \
    HANG_UPLOAD=1 BUILDKITE_PLUGIN_COREUPLOAD_UPLOAD_TIMEOUT=1
# A truncated core, from which the debugger can't list any images
run no_images "${P}3.core ${P}1.core ${P}2.core " "${P}3.core.tar.zst " NO_IMAGES=1
# lldb finds no executable in a FreeBSD core; it must be given the one procstat reports
run freebsd "${P}3.core ${P}1.core ${P}2.core " "${P}3.core.zst " \
    FREEBSD=1 BUILDKITE_PLUGIN_COREUPLOAD_CREATE_BUNDLE=false WANT_EXE='fake exe'
# Appending makes julia-pid1.core the newest
run growing "${P}3.core ${P}2.core ${P}1.core " "${P}3.core.tar.zst ${P}2.core.tar.zst ${P}1.core.tar.zst " \
    GROW=1 BUILDKITE_PLUGIN_COREUPLOAD_MAX_UPLOADS=3
run low_disk "${P}3.core ${P}1.core ${P}2.core " "" FREE_KIB=$(( 6 * 1024 * 1024 ))

exit "${FAILURES}"
