#!/usr/bin/env bash
# Capture diagnostics from a hung EqTool running under Proton/Wine.
#
# Usage:  ./capture-eqtool-hang.sh [pid]
#
# With no argument it picks the EQTool.exe process with the most threads, which
# is the app itself rather than one of Wine's helper processes. Run it while the
# app is still hung - before letting GNOME kill it.

set -uo pipefail

# Where the capture lands. Override with EQTOOL_OUT_DIR.
OUT="${EQTOOL_OUT_DIR:-$HOME}/eqtool-hang-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# Walk /proc directly rather than shelling out to ps, so this works the same on a
# minimal system and so the match is against the real cmdline (NUL-separated)
# instead of whatever column layout ps happens to produce.
# Prints "threads pid cmdline", one per line, highest thread count first.
list_candidates() {
    local pattern="${1:-EQTool\.exe}"
    local p tid_count cmd
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cmd" in
            *capture-eqtool-hang*) continue ;;
        esac
        if printf '%s' "$cmd" | grep -qi -- "$pattern"; then
            tid_count=$(ls "$p/task" 2>/dev/null | wc -l)
            printf '%s %s %s\n' "$tid_count" "$(basename "$p")" "$cmd"
        fi
    done | sort -k1 -rn
}

pick_pid() {
    # Highest thread count wins: the .NET app carries dozens of threads while
    # services.exe / plugplay.exe / winedevice.exe carry only a few.
    list_candidates | awk 'NR==1{print $2}'
}

PID="${1:-$(pick_pid)}"

if [ -z "${PID:-}" ] || [ ! -d "/proc/$PID" ]; then
    echo "Could not find a running EQTool.exe process." >&2
    echo "Processes matching 'wine' or 'exe', as threads/pid/cmdline:" >&2
    list_candidates 'wine\|\.exe' >&2 | head -20
    echo "Re-run with an explicit pid once you spot it: $0 <pid>" >&2
    exit 1
fi

THREADS=$(ls "/proc/$PID/task" 2>/dev/null | wc -l)
echo "Capturing pid $PID ($THREADS threads) -> $OUT"

# All EQTool/wine processes, so the chosen pid can be sanity-checked later.
{
    echo "THREADS PID CMDLINE"
    list_candidates 'EQTool\|wine\|steam'
} > "$OUT/processes.txt" 2>&1

# Thread count is the headline number: a starved pool keeps climbing.
{
    echo "pid=$PID"
    echo "threads=$THREADS"
    echo "cmdline=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)"
    echo "state=$(awk '/^State:/{print $2,$3}' "/proc/$PID/status" 2>/dev/null)"
} > "$OUT/summary.txt" 2>&1

# Per-thread kernel stacks and wait channels. Threads parked in a socket read or
# a futex wait show up here without needing gdb at all.
for t in /proc/"$PID"/task/*; do
    tid=$(basename "$t")
    {
        echo "=== tid $tid ==="
        echo "--- comm: $(cat "$t/comm" 2>/dev/null)"
        echo "--- state: $(awk '/^State:/{print $2,$3}' "$t/status" 2>/dev/null)"
        echo "--- wchan: $(cat "$t/wchan" 2>/dev/null)"
        echo
    } >> "$OUT/threads.txt" 2>&1
done

# Open sockets: a pile of connections to pigparse.azurewebsites.net stuck in
# ESTABLISHED or SYN-SENT is direct evidence of stalled HTTP calls.
{
    echo "=== ss -tnp for pid $PID ==="
    ss -tnp 2>/dev/null | grep -e "pid=$PID" -e 'State'
    echo
    echo "=== all outbound https ==="
    ss -tn 2>/dev/null | head -50
} > "$OUT/sockets.txt" 2>&1

# Native backtraces. Under Wine these show Wine/ntdll frames rather than C#
# method names, but "N threads all parked in the same wait" is the point.
if command -v gdb >/dev/null 2>&1; then
    timeout 120 gdb -p "$PID" -batch \
        -ex "set pagination off" \
        -ex "thread apply all bt" \
        > "$OUT/gdb-backtrace.txt" 2>&1
    echo "gdb backtrace captured."
else
    echo "gdb not installed - skipping backtrace (install with: sudo dnf install gdb)" \
        | tee "$OUT/gdb-backtrace.txt"
fi

# Kernel ring buffer, in case this was a GPU reset or an OOM kill rather than a
# managed-side hang.
journalctl -k -b --no-pager 2>/dev/null | tail -200 > "$OUT/dmesg.txt" 2>&1

echo
echo "Done. Collected in: $OUT"
echo "  summary.txt       pid, thread count, process state"
echo "  threads.txt       per-thread state and wait channel"
echo "  sockets.txt       open connections (look for pigparse)"
echo "  gdb-backtrace.txt native stacks"
echo "  processes.txt     all EQTool/wine processes"
echo "  dmesg.txt         kernel log (GPU resets, OOM)"
echo
echo "Thread count was $THREADS - anything in the hundreds points at pool starvation."
