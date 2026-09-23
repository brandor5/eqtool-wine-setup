#!/usr/bin/env bash
# Track EqTool's memory and thread count over a session.
#
# Usage:  ./watch-eqtool-memory.sh [interval_seconds] [pid]
#
#   interval_seconds  how often to sample (default 30)
#   pid               pin to one process; omit to find EQTool.exe automatically
#
# Leave it running in a spare terminal for a few hours. Ctrl-C to stop - it
# prints a verdict on exit and leaves a CSV behind.
#
# What the numbers mean:
#   RSS      resident memory. Steady climb that never falls back = a leak.
#   VmSize   virtual address space. This is what ran out on the 32-bit build.
#   threads  ~26 is normal. Climbing into the hundreds = the pool is starved,
#            which is what the 394-thread hang looked like.

set -uo pipefail

INTERVAL="${1:-30}"
PIN_PID="${2:-}"

# Where the CSV lands. Override with EQTOOL_OUT_DIR if you keep diagnostics
# somewhere particular.
LOG_DIR="${EQTOOL_OUT_DIR:-$HOME}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/eqtool-memory-$(date +%Y%m%d-%H%M%S).csv"

# Highest thread count among EQTool.exe processes is the app; the rest are
# Wine helpers. Walks /proc so it does not depend on ps being installed.
find_pid() {
    local p cmd t best_t=-1 best_p=""
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cmd" in
            *watch-eqtool-memory*) continue ;;
            # Steam's launcher chain all carry EQTool.exe as an argument: the
            # steam.exe shim, reaper, pressure-vessel, and proton's python
            # wrapper. Only the Wine process whose own image is EQTool.exe is
            # the app; the shim in particular sits at a steady 3 threads and
            # would otherwise look like a perfectly flat memory graph.
            *steam.exe*|*reaper*|*pressure-vessel*|*pv-adverb*|*proton*|*python3*) continue ;;
            *EQTool.exe*) ;;
            *) continue ;;
        esac
        t=$(ls "$p/task" 2>/dev/null | wc -l)
        if [ "$t" -gt "$best_t" ]; then best_t=$t; best_p=${p#/proc/}; fi
    done
    printf '%s' "$best_p"
}

# A real WPF app under Wine carries well over this many threads; anything at or
# below it is a launcher shim we should not be measuring.
MIN_PLAUSIBLE_THREADS=8

# VmRSS / VmPeak / VmSize are reported in kB in /proc/<pid>/status.
status_kb() {
    awk -v f="$2:" '$1==f {print $2; exit}' "/proc/$1/status" 2>/dev/null
}

summarise() {
    if [ "${samples:-0}" -lt 2 ]; then
        echo
        echo "Not enough samples for a trend. CSV: $LOG"
        return
    fi
    echo
    echo "─────────────────────────────────────────────"
    awk -v s="$start_rss" -v e="$last_rss" -v t="$elapsed" -v th0="$start_threads" -v th="$last_threads" '
    BEGIN {
        hours = t / 3600.0;
        d = (e - s) / 1024.0;
        printf "Ran for          %.1f min\n", t/60.0;
        printf "RSS              %.0f MB -> %.0f MB  (%+.0f MB)\n", s/1024.0, e/1024.0, d;
        printf "Threads          %d -> %d\n", th0, th;
        if (hours > 0.01) {
            rate = d / hours;
            printf "Growth rate      %+.1f MB/hour\n", rate;
            print "";
            if (rate > 50)       print "VERDICT: climbing fast - a real leak. Worth chasing.";
            else if (rate > 10)  print "VERDICT: climbing steadily - likely a leak, watch longer.";
            else if (rate > -10) print "VERDICT: flat. No leak visible over this window.";
            else                 print "VERDICT: net decrease - GC is reclaiming. Healthy.";
        } else {
            print "Ran too briefly to estimate a rate - leave it running longer.";
        }
        if (th - th0 > 50) {
            print "";
            print "NOTE: thread count climbed a lot. That is the starvation signature -";
            print "      run capture-eqtool-hang.sh while it is still up.";
        }
    }'
    echo "─────────────────────────────────────────────"
    echo "CSV: $LOG"
}

trap 'summarise; exit 0' INT TERM

PID="${PIN_PID:-$(find_pid)}"
while [ -z "$PID" ] || [ ! -d "/proc/$PID" ] || \
      { [ -z "$PIN_PID" ] && [ "$(ls "/proc/$PID/task" 2>/dev/null | wc -l)" -le "$MIN_PLAUSIBLE_THREADS" ]; }; do
    echo "Waiting for EQTool.exe to start (no process with more than $MIN_PLAUSIBLE_THREADS threads yet)..."
    sleep "$INTERVAL"
    PID=$(find_pid)
done

echo "pid,iso_time,elapsed_s,threads,rss_kb,vmsize_kb,vmpeak_kb" > "$LOG"
echo "Watching pid $PID every ${INTERVAL}s. Ctrl-C for a summary."
printf '%-9s %-8s %10s %12s %12s\n' "TIME" "THREADS" "RSS_MB" "VMSIZE_MB" "DELTA_MB"

start_time=$(date +%s)
samples=0
start_rss=0
start_threads=0
last_rss=0
last_threads=0
elapsed=0

while true; do
    if [ ! -d "/proc/$PID" ]; then
        echo "pid $PID is gone (app exited or was killed)."
        newpid=$(find_pid)
        if [ -n "$newpid" ] && [ "$newpid" != "$PID" ]; then
            echo "Found a new EQTool.exe at pid $newpid - restarting the baseline."
            PID=$newpid
            samples=0
            start_time=$(date +%s)
        else
            summarise
            exit 0
        fi
    fi

    threads=$(ls "/proc/$PID/task" 2>/dev/null | wc -l)

    # If what we latched onto looks like a shim, keep looking: the real app may
    # have started after we did, and the shim will not exit to trigger the
    # dead-pid path below.
    if [ -z "$PIN_PID" ] && [ "$threads" -le "$MIN_PLAUSIBLE_THREADS" ]; then
        better=$(find_pid)
        if [ -n "$better" ] && [ "$better" != "$PID" ] && \
           [ "$(ls "/proc/$better/task" 2>/dev/null | wc -l)" -gt "$MIN_PLAUSIBLE_THREADS" ]; then
            echo "pid $PID looks like a launcher shim ($threads threads); switching to pid $better."
            PID=$better
            samples=0
            start_time=$(date +%s)
            threads=$(ls "/proc/$PID/task" 2>/dev/null | wc -l)
        fi
    fi

    rss=$(status_kb "$PID" VmRSS)
    vmsize=$(status_kb "$PID" VmSize)
    vmpeak=$(status_kb "$PID" VmPeak)
    [ -z "${rss:-}" ] && { sleep "$INTERVAL"; continue; }

    now=$(date +%s)
    elapsed=$((now - start_time))

    if [ "$samples" -eq 0 ]; then
        start_rss=$rss
        start_threads=$threads
    fi
    samples=$((samples + 1))
    last_rss=$rss
    last_threads=$threads

    echo "$PID,$(date -Is),$elapsed,$threads,$rss,${vmsize:-0},${vmpeak:-0}" >> "$LOG"
    awk -v t="$(date +%H:%M:%S)" -v th="$threads" -v r="$rss" -v v="${vmsize:-0}" -v s="$start_rss" \
        'BEGIN { printf "%-9s %-8s %10.0f %12.0f %+12.0f\n", t, th, r/1024.0, v/1024.0, (r-s)/1024.0 }'

    sleep "$INTERVAL"
done
