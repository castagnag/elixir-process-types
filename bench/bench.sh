#!/usr/bin/env bash
# bench/bench.sh [RUNS]: the measurements of the appendix "Prototype Measurements" of the
# paper. See bench/README.md.
#
#   RUNS      runs of each line, each in a fresh VM; the fastest is kept (default 3)
#   TIMEOUT   seconds allowed to one run (default 900)
#   ABLATION  0 to skip inference without each change of tallying (the slowest lines)
#   OUT       output directory (default bench/out/<host>-<date>)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export LC_NUMERIC=C

RUNS=${1:-${RUNS:-3}}
TIMEOUT=${TIMEOUT:-900}
ABLATION=${ABLATION:-1}
host=$(hostname -s 2>/dev/null || hostname)
out=${OUT:-bench/out/$host-$(date +%Y%m%d)}

die() { echo "bench: $*" >&2; exit 1; }

command -v mix >/dev/null || die "mix not found: install Elixir (1.20 or later)"
mix compile >/dev/null || die "the prototype does not compile"

rm -rf "$out"
mkdir -p "$out/programs"

run_limited() { "$@"; }
if command -v timeout >/dev/null; then run_limited() { timeout "$TIMEOUT" "$@"; }
elif command -v gtimeout >/dev/null; then run_limited() { gtimeout "$TIMEOUT" "$@"; }
else echo "bench: no timeout command, runs are not limited" >&2; fi

# Wall clock in nanoseconds (GNU date, or perl where date has no %N).
now() {
  local t
  t=$(date +%s%N)
  case "$t" in *N) perl -MTime::HiRes=time -e 'printf "%d\n", time * 1e9' ;; *) echo "$t" ;; esac
}

# --- The machine ---------------------------------------------------------------------

cpu=$( (lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1) || true)
[ -n "$cpu" ] || cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown processor")
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "?")
if [ -r /proc/meminfo ]; then mem=$(awk '/MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo)
else mem=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )); fi
if [ -r /etc/os-release ]; then os=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)
else os=$(uname -sr); fi
versions=$(elixir -e 'IO.puts(System.version() <> " " <> List.to_string(:erlang.system_info(:otp_release)))')
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
[ -z "$(git status --porcelain -- lib examples mix.exs mix.lock 2>/dev/null)" ] || commit="$commit, modified"

echo "bench: start of the VM" >&2
vm_start=""
for _ in $(seq "$RUNS"); do
  t0=$(now); mix run -e ':ok' >/dev/null 2>&1; t1=$(now)
  ms=$(( (t1 - t0) / 1000000 ))
  if [ -z "$vm_start" ] || [ "$ms" -lt "$vm_start" ]; then vm_start=$ms; fi
done

cat > "$out/machine.txt" <<EOF
host=$host
date=$(date +%Y-%m-%d)
cpu=$cpu
cores=$cores
memory=$mem
os=$os
elixir=${versions% *}
otp=${versions#* }
commit=$commit
runs=$RUNS
timeout=$TIMEOUT
vm_start=$vm_start
EOF

# --- The variants --------------------------------------------------------------------
# A reconstruction variant is a program without some of its $interface lines. The
# number of lines removed is checked, so that a change of the examples is noticed.

without() { # without NAME SOURCE LINES PATTERN
  grep -vE "$4" "$2" > "$out/programs/$1.exs"
  local removed=$(( $(wc -l < "$2") - $(wc -l < "$out/programs/$1.exs") ))
  [ "$removed" -eq "$3" ] || die "$2: $removed lines removed for $1, $3 expected"
}

every='^[[:space:]]*\$interface[[:space:]]'   # every $interface (not $self_interface)
inner='^[[:space:]]+\$interface[[:space:]]'   # the indented ones: the worker's spawn

without basic_decorated_recon bench/programs/basic_decorated.exs 2 "$every"
without basic_recon           bench/programs/basic.exs           2 "$every"
without jobs_decorated_recon  examples/server_decorated.exs      1 "$inner"
without jobs_recon            examples/server.exs                1 "$inner"

# The rejected server, with the decorations of job removed.
sed -E 's/^([[:space:]]*\$type job[[:space:]]*= \(-> term\(\)\))@\[.*\]$/\1/' \
  examples/server_errors.exs > "$out/programs/errors_job_undecorated.exs"
cmp -s examples/server_errors.exs "$out/programs/errors_job_undecorated.exs" &&
  die "examples/server_errors.exs: the decorations of job were not found"

# --- The runs ------------------------------------------------------------------------

: > "$out/results.csv"
: > "$out/rows.txt"

row() { # row ID TABLE FILE MODE LABELS [KEY=VALUE ...]
  local id=$1 table=$2 file=$3 mode=$4 labels=$5 line code
  shift 5
  echo "$id|$table|$mode|$labels" >> "$out/rows.txt"
  for r in $(seq "$RUNS"); do
    line=$(run_limited mix run bench/measure.exs "$file" "$mode" "$@" 2>/dev/null | tail -n 1)
    code=$?
    if [ "$code" -eq 124 ]; then
      echo "$id,$r,timeout" >> "$out/results.csv"
      echo "bench: $id run $r: no answer in $TIMEOUT s" >&2
      break
    elif ! echo "$line" | grep -qE '^(accepted|rejected:[0-9]+)(,[0-9.]+){11}$'; then
      echo "$id,$r,failed" >> "$out/results.csv"
      echo "bench: $id run $r: failed ($line)" >&2
      break
    fi
    echo "$id,$r,$line" >> "$out/results.csv"
    echo "bench: $id run $r: $line" >&2
  done
}

p=$out/programs

# Table 1: decorations written or inferred, interfaces declared or reconstructed.
row c1 configs bench/programs/basic_decorated.exs infer        "server|written|declared"
row c2 configs "$p/basic_decorated_recon.exs"     reconstruct  "server|written|reconstructed"
row c3 configs bench/programs/basic.exs           infer        "server|inferred|declared"
row c4 configs "$p/basic_recon.exs"               reconstruct  "server|inferred|reconstructed"
row c5 configs examples/server_decorated.exs      infer        "server with jobs|written|declared"
row c6 configs "$p/jobs_decorated_recon.exs"      reconstruct  "server with jobs|written|reconstructed"
row c7 configs examples/server.exs                infer        "server with jobs|inferred|declared"
row c8 configs "$p/jobs_recon.exs"                reconstruct  "server with jobs|inferred|reconstructed"

# Table 2: the steps of the reconstruction.
row s1 steps examples/recon_bank.exs             reconstruct "bank account"
row s2 steps examples/recon_server.exs           reconstruct "server"
row s3 steps examples/recon_jobs.exs             reconstruct "server with jobs"
row s4 steps examples/recon_forward.exs          reconstruct "forwarding"
row s5 steps examples/recon_appendix.exs         reconstruct "appendix examples"
row s6 steps examples/recon_closure.exs          reconstruct "closure sent to a pid"
row s7 steps examples/recon_limits_too_large.exs reconstruct "interface too large"

# Table 3: locating errors, and inference without a change of tallying.
row e1 tallying examples/server_errors.exs        infer "ill-typed sends|written|as described"
row e2 tallying "$p/errors_job_undecorated.exs"   infer "ill-typed sends|written, except for the jobs|as described"
if [ "$ABLATION" = 1 ]; then
  row a0 tallying examples/server.exs infer "server with jobs|inferred|as described"
  row a1 tallying examples/server.exs infer "server with jobs|inferred|no elimination" eliminate=false
  row a2 tallying examples/server.exs infer "server with jobs|inferred|all the solutions" tally=all
fi

elixir bench/report.exs "$out" || die "the report failed"
echo "bench: results in $out (tables.md, measurements-*.tex)" >&2
