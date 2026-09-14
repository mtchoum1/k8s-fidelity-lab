#!/usr/bin/env bash
# Time and resource metrics for fidelity-lab tiers.
# Sourced by lab-lib.sh and tier runner scripts.
set -euo pipefail

: "${LAB_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${LAB_STATE_DIR:=${LAB_ROOT}/.lab}"
LAB_METRICS_CSV="${LAB_STATE_DIR}/tier-metrics.csv"
LAB_METRICS_STATE="${LAB_STATE_DIR}/metrics-state.env"

lab_metrics_ensure_dir() {
  mkdir -p "$LAB_STATE_DIR"
}

lab_metrics_tier_tool() {
  case "${1:-}" in
    1) echo "envtest" ;;
    2) echo "KWOK" ;;
    3) echo "kind" ;;
    4) echo "tilt" ;;
    5) echo "rhoai-in-kind" ;;
    6) echo "argocd" ;;
    7) echo "OpenShift" ;;
    *) echo "unknown" ;;
  esac
}

lab_metrics_init_csv() {
  lab_metrics_ensure_dir
  if [[ ! -f "$LAB_METRICS_CSV" ]]; then
    cat >"$LAB_METRICS_CSV" <<'EOF'
timestamp,tier,tool,scenario,status,setup_time_s,elapsed_s,max_ram_mb,avg_cpu_pct,notes
EOF
  fi
}

lab_metrics_load_state() {
  if [[ -f "$LAB_METRICS_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$LAB_METRICS_STATE"
  fi
}

lab_metrics_save_state() {
  lab_metrics_ensure_dir
  cat >"$LAB_METRICS_STATE" <<EOF
LAB_METRICS_TIER=${LAB_METRICS_TIER:-}
LAB_METRICS_START=${LAB_METRICS_START:-}
LAB_METRICS_SETUP_END=${LAB_METRICS_SETUP_END:-}
LAB_METRICS_STATS_FILE=${LAB_METRICS_STATS_FILE:-}
LAB_METRICS_SAMPLER_FLAG=${LAB_METRICS_SAMPLER_FLAG:-}
LAB_METRICS_SAMPLER_PID=${LAB_METRICS_SAMPLER_PID:-}
EOF
}

lab_metrics_collect_pids() {
  local root_pid="${1:-}"
  local seen="${2:-}"
  local child

  [[ -n "$root_pid" ]] || return 0
  case " $seen " in
    *" $root_pid "*) return 0 ;;
  esac
  seen="${seen} ${root_pid}"
  echo "$root_pid"
  for child in $(pgrep -P "$root_pid" 2>/dev/null || true); do
    lab_metrics_collect_pids "$child" "$seen"
  done
}

lab_metrics_start_sampler() {
  local root_pid="${1:-$$}"
  local stats_file sampler_flag

  stats_file="$(mktemp "${TMPDIR:-/tmp}/lab-metrics-stats.XXXXXX")"
  sampler_flag="$(mktemp "${TMPDIR:-/tmp}/lab-metrics-sampler.XXXXXX")"

  (
    local pid total_rss total_cpu sample_rss sample_cpu
    while [[ -f "$sampler_flag" ]]; do
      total_rss=0
      total_cpu=0
      while read -r pid; do
        [[ -z "$pid" ]] && continue
        read -r sample_rss sample_cpu < <(ps -o rss=,pcpu= -p "$pid" 2>/dev/null | awk '{rss+=$1; cpu+=$2} END {print rss+0, cpu+0}')
        total_rss=$((total_rss + sample_rss))
        total_cpu=$(awk "BEGIN {print $total_cpu + $sample_cpu}")
      done < <(lab_metrics_collect_pids "$root_pid")
      echo "${total_rss} ${total_cpu}" >>"$stats_file"
      sleep 1
    done
  ) &
  LAB_METRICS_SAMPLER_PID=$!
  LAB_METRICS_STATS_FILE="$stats_file"
  LAB_METRICS_SAMPLER_FLAG="$sampler_flag"
}

lab_metrics_stop_sampler() {
  if [[ -n "${LAB_METRICS_SAMPLER_FLAG:-}" ]] && [[ -f "$LAB_METRICS_SAMPLER_FLAG" ]]; then
    rm -f "$LAB_METRICS_SAMPLER_FLAG"
  fi
  if [[ -n "${LAB_METRICS_SAMPLER_PID:-}" ]]; then
    wait "$LAB_METRICS_SAMPLER_PID" 2>/dev/null || true
  fi
}

lab_metrics_parse_stats() {
  local stats_file="${1:-}"
  local max_ram_kb=0 avg_cpu=0 sum_cpu=0 count=0 rss cpu

  if [[ -z "$stats_file" ]] || [[ ! -f "$stats_file" ]]; then
    echo "0 0"
    return
  fi

  while read -r rss cpu; do
    [[ -z "$rss" ]] && continue
    if [[ "$rss" -gt "$max_ram_kb" ]]; then
      max_ram_kb=$rss
    fi
    sum_cpu=$(awk "BEGIN {print $sum_cpu + $cpu}")
    count=$((count + 1))
  done <"$stats_file"

  if [[ "$count" -gt 0 ]]; then
    avg_cpu=$(awk "BEGIN {printf \"%.1f\", $sum_cpu / $count}")
  else
    avg_cpu="0"
  fi

  # RSS from ps is KiB on Linux and macOS.
  local max_ram_mb
  max_ram_mb=$(awk "BEGIN {printf \"%.0f\", $max_ram_kb / 1024}")
  echo "$max_ram_mb $avg_cpu"
}

lab_metrics_begin() {
  local tier="${1:-}"
  [[ -n "$tier" ]] || return 0

  lab_metrics_init_csv
  LAB_METRICS_TIER="$tier"
  LAB_METRICS_START="$(date +%s)"
  LAB_METRICS_SETUP_END=""
  lab_metrics_start_sampler "$$"
  lab_metrics_save_state
}

lab_metrics_handoff() {
  local notes="${1:-interactive phase}"
  lab_metrics_load_state
  [[ -n "${LAB_METRICS_TIER:-}" ]] || return 0
  [[ -z "${LAB_METRICS_SETUP_END:-}" ]] || return 0

  LAB_METRICS_SETUP_END="$(date +%s)"
  lab_metrics_save_state

  local setup_s tool
  setup_s=$((LAB_METRICS_SETUP_END - LAB_METRICS_START))
  tool="$(lab_metrics_tier_tool "$LAB_METRICS_TIER")"
  echo ""
  echo "=== Tier ${LAB_METRICS_TIER} (${tool}) setup complete in ${setup_s}s — ${notes} ==="
  lab_metrics_print_setup_summary
}

lab_metrics_print_setup_summary() {
  lab_metrics_load_state
  [[ -n "${LAB_METRICS_TIER:-}" ]] || return 0

  local setup_end="${LAB_METRICS_SETUP_END:-$(date +%s)}"
  local setup_s=$((setup_end - LAB_METRICS_START))
  read -r max_ram avg_cpu < <(lab_metrics_parse_stats "${LAB_METRICS_STATS_FILE:-}")

  echo "  Setup time:  ${setup_s}s"
  echo "  Peak RAM:    ${max_ram} MB (process group sample)"
  echo "  Avg CPU:     ${avg_cpu}% (process group sample)"
}

lab_metrics_end() {
  local status="${1:-ok}"
  local notes="${2:-}"

  lab_metrics_load_state
  [[ -n "${LAB_METRICS_TIER:-}" ]] || return 0

  lab_metrics_stop_sampler

  local end_time setup_end setup_s elapsed_s max_ram avg_cpu tool scenario
  end_time="$(date +%s)"
  setup_end="${LAB_METRICS_SETUP_END:-$end_time}"
  setup_s=$((setup_end - LAB_METRICS_START))
  elapsed_s=$((end_time - LAB_METRICS_START))
  read -r max_ram avg_cpu < <(lab_metrics_parse_stats "${LAB_METRICS_STATS_FILE:-}")
  tool="$(lab_metrics_tier_tool "$LAB_METRICS_TIER")"
  scenario="${LAB_SCENARIO:-pr104}"

  lab_metrics_init_csv
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -Iseconds)" \
    "$LAB_METRICS_TIER" \
    "$tool" \
    "$scenario" \
    "$status" \
    "$setup_s" \
    "$elapsed_s" \
    "$max_ram" \
    "$avg_cpu" \
    "$notes" >>"$LAB_METRICS_CSV"

  echo ""
  echo "=== Tier ${LAB_METRICS_TIER} (${tool}) metrics recorded ==="
  echo "  Status:      ${status}"
  echo "  Setup time:  ${setup_s}s"
  echo "  Elapsed:     ${elapsed_s}s"
  echo "  Peak RAM:    ${max_ram} MB"
  echo "  Avg CPU:     ${avg_cpu}%"
  echo "  Log:         ${LAB_METRICS_CSV}"

  rm -f "${LAB_METRICS_STATS_FILE:-}" "${LAB_METRICS_SAMPLER_FLAG:-}" "$LAB_METRICS_STATE"
  unset LAB_METRICS_TIER LAB_METRICS_START LAB_METRICS_SETUP_END
  unset LAB_METRICS_STATS_FILE LAB_METRICS_SAMPLER_FLAG LAB_METRICS_SAMPLER_PID
}

lab_metrics_show() {
  lab_metrics_init_csv
  if [[ ! -s "$LAB_METRICS_CSV" ]] || [[ "$(wc -l <"$LAB_METRICS_CSV")" -le 1 ]]; then
    echo "No tier metrics recorded yet. Run: ./lab run <tier>"
    return 0
  fi

  echo "Tier metrics (latest run per tier):"
  echo ""
  column -t -s, "$LAB_METRICS_CSV" 2>/dev/null || cat "$LAB_METRICS_CSV"
  echo ""
  echo "Full log: ${LAB_METRICS_CSV}"
}

# Wrap a bounded command with /usr/bin/time for peak RSS (used by measure.sh).
lab_metrics_run_timed() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || return 1

  local output_tmp start end elapsed max_rss_kb max_ram_mb
  output_tmp="$(mktemp "${TMPDIR:-/tmp}/lab-measure.XXXXXX")"
  start="$(date +%s)"

  set +e
  if [[ "$(uname -s)" == "Darwin" ]]; then
    /usr/bin/time -l bash -c "$cmd" >"$output_tmp" 2>&1
  elif command -v gtime &>/dev/null; then
    gtime -v bash -c "$cmd" >"$output_tmp" 2>&1
  else
    /usr/bin/time -v bash -c "$cmd" >"$output_tmp" 2>&1
  fi
  local cmd_exit=$?
  set -e

  cat "$output_tmp"
  end="$(date +%s)"
  elapsed=$((end - start))

  max_rss_kb="$(grep -E "Maximum resident set size|maximum resident set size" "$output_tmp" \
    | awk '{print $NF}' | tail -1)"
  max_rss_kb="${max_rss_kb:-0}"
  max_ram_mb=$(awk "BEGIN {printf \"%.0f\", $max_rss_kb / (1024*1024)}")
  if [[ "$max_ram_mb" == "0" ]] && [[ "$max_rss_kb" -gt 1024 ]]; then
    # BSD time reports bytes; Linux GNU time reports KiB.
    max_ram_mb=$(awk "BEGIN {printf \"%.0f\", $max_rss_kb / 1024}")
  fi

  echo "--------------------------------------"
  echo "Total Time Elapsed: ${elapsed} seconds"
  grep -E "Maximum resident set size|maximum resident set size" "$output_tmp" || true
  rm -f "$output_tmp"

  if command -v podman &>/dev/null; then
    echo "Podman container stats (if any running):"
    podman stats --no-stream 2>/dev/null || true
  fi

  LAB_METRICS_LAST_ELAPSED_S="$elapsed"
  LAB_METRICS_LAST_MAX_RAM_MB="$max_ram_mb"
  return "$cmd_exit"
}
