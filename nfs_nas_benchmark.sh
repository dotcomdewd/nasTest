#!/usr/bin/env bash
# NFS NAS Benchmark Toolkit
# Tests: NFS sequential read/write (dd), fio throughput & IOPS, iperf3 network bandwidth, and mount/link diagnostics.
# Works on Ubuntu 20.04/22.04/24.04. Run as a user with sudo privileges.
set -euo pipefail

VERSION="1.3"

# ----------------------------- Utils -----------------------------
RED="$(tput setaf 1 || true)"; GREEN="$(tput setaf 2 || true)"; YELLOW="$(tput setaf 3 || true)"; BLUE="$(tput setaf 4 || true)"; BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
log() { echo -e "${BLUE}[+]${RESET} $*"; }
ok() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err() { echo -e "${RED}[ERR]${RESET} $*" 1>&2; }

REQ_PKGS=(fio iperf3 ethtool nfs-common coreutils util-linux procps)
LOG_DIR="${HOME}/nfs_bench_logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/nfs_benchmark_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/nfs_benchmark_summary_${TIMESTAMP}.txt"

tee_log() { tee -a "$LOG_FILE"; }

# Run a command, print it, and tee output to log
run_and_log() {
  echo -e "\n${BOLD}\$ $*${RESET}" | tee_log
  # shellcheck disable=SC2068
  "$@" 2>&1 | tee_log
}

# Run a command, print it, tee to log, and also capture stdout/stderr into a variable
run_capture() {
  # usage: out="$(run_capture cmd args...)"
  echo -e "\n${BOLD}\$ $*${RESET}" | tee_log
  local out
  out="$("$@" 2>&1 | tee -a "$LOG_FILE")"
  echo "$out"
}

# ----------------------------- Dependency check -----------------------------
need_sudo() {
  if [[ "$(id -u)" -ne 0 ]]; then
    SUDO="sudo -n"
    if ! $SUDO true 2>/dev/null; then
      warn "Some actions need sudo. You'll be prompted as needed."
      SUDO="sudo"
    fi
  else
    SUDO=""
  fi
}

install_deps() {
  need_sudo
  log "Checking required packages: ${REQ_PKGS[*]}"
  MISSING=()
  for p in "${REQ_PKGS[@]}"; do
    dpkg -s "$p" &>/dev/null || MISSING+=("$p")
  done
  if ((${#MISSING[@]})); then
    log "Installing missing packages: ${MISSING[*]}"
    $SUDO apt-get update -y | tee_log
    $SUDO apt-get install -y "${MISSING[@]}" | tee_log
  else
    ok "All required packages present."
  fi
}

# ----------------------------- NFS mount selection -----------------------------
list_nfs_mounts() {
  awk '$3 ~ /^nfs/ {print $2 "  <-  " $1 "  (" $3 ")"}' /proc/mounts
}

choose_mountpoint() {
  local mounts
  mapfile -t mounts < <(awk '$3 ~ /^nfs/ {print $2 "|" $1 "|" $3}' /proc/mounts)
  if ((${#mounts[@]} == 0)); then
    err "No NFS mounts detected. Please mount your NAS first (e.g., via /etc/fstab or mount command)."
    exit 1
  fi
  echo
  echo "Detected NFS mounts:" | tee_log
  local i=1
  for m in "${mounts[@]}"; do
    IFS="|" read -r mp src fstype <<<"$m"
    echo "  [$i] $mp  <-  $src  ($fstype)"
    ((i++))
  done
  echo -n "Select mount [1-${#mounts[@]}] or enter a path manually: "
  read -r choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#mounts[@]} )); then
    IFS="|" read -r MOUNTPOINT NFS_SRC NFS_TYPE <<<"${mounts[$((choice-1))]}"
  else
    MOUNTPOINT="$choice"
    if ! mountpoint -q -- "$MOUNTPOINT"; then
      err "Provided path is not a mountpoint: $MOUNTPOINT"
      exit 1
    fi
    # Try to determine source/type for info
    NFS_SRC="$(awk -v mp="$MOUNTPOINT" '$2==mp{print $1}' /proc/mounts)"
    NFS_TYPE="$(awk -v mp="$MOUNTPOINT" '$2==mp{print $3}' /proc/mounts)"
  fi
  TEST_DIR="${MOUNTPOINT}/.nfs_bench_${TIMESTAMP}"
  mkdir -p "$TEST_DIR"
  ok "Using NFS mountpoint: $MOUNTPOINT (source: ${NFS_SRC:-unknown}, type: ${NFS_TYPE:-unknown})"
  echo "Mount details:" | tee_log
  grep " $MOUNTPOINT " /proc/mounts | tee_log || true
}

# ----------------------------- Diagnostics -----------------------------
show_diagnostics() {
  echo -e "\n=== System & NFS Diagnostics ===" | tee_log
  run_and_log uname -a
  echo -e "\n-- NFS mounts --" | tee_log
  list_nfs_mounts | tee_log || true
  echo -e "\n-- nfsstat -m --" | tee_log
  run_and_log nfsstat -m || true
  echo -e "\n-- df -hT $MOUNTPOINT --" | tee_log
  run_and_log df -hT "$MOUNTPOINT"
  echo -e "\n-- Network route to NAS source (if known) --" | tee_log
  if [[ -n "${NFS_SRC:-}" ]]; then
    NAS_HOST="${NFS_SRC%%:*}"
    # Resolve to IP if hostname
    NAS_IP="$(getent ahostsv4 "$NAS_HOST" | awk 'NR==1{print $1}')"
    if [[ -n "$NAS_IP" ]]; then
      echo "NAS resolved IP: $NAS_IP" | tee_log
      DEF_IFACE="$(ip route get "$NAS_IP" 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
      if [[ -n "$DEF_IFACE" ]]; then
        echo "Outbound interface to NAS: $DEF_IFACE" | tee_log
        echo -e "\n-- ethtool $DEF_IFACE --" | tee_log
        run_and_log ethtool "$DEF_IFACE" || true
        echo -e "\n-- ip -s link show $DEF_IFACE --" | tee_log
        run_and_log ip -s link show "$DEF_IFACE" || true
      fi
    fi
  fi
}

# ----------------------------- Result collectors -----------------------------
SUMMARY_DD_WRITE="N/A"
SUMMARY_DD_READ="N/A"
SUMMARY_FIO_SEQ_READ="N/A"
SUMMARY_FIO_SEQ_WRITE="N/A"
SUMMARY_FIO_RAND_RIOPS="N/A"
SUMMARY_FIO_RAND_WIOPS="N/A"
SUMMARY_IPERF="N/A"
ANY_TEST_RAN=0

# ----------------------------- dd tests -----------------------------
DD_SIZE_DEFAULT="2G"
dd_tests() {
  local size="${1:-$DD_SIZE_DEFAULT}"
  echo -e "\n=== dd Sequential Write/Read Test (size=${size}) ===" | tee_log
  local testfile="${TEST_DIR}/dd_test.bin"

  # Compute MiB count
  local mib_count
  case "$size" in
    *G|*g) mib_count=$(( $(numfmt --from=iec "$size") / 1048576 )) ;;
    *M|*m) mib_count=$(( $(numfmt --from=iec "$size") / 1048576 )) ;;
    *) mib_count=$(( $(numfmt --from=iec "$size") / 1048576 )) ;;
  esac

  # Write test
  echo -e "\n-- Write test: dd if=/dev/zero of=$testfile bs=1M count=${mib_count} conv=fdatasync --" | tee_log
  local write_out
  write_out="$(run_capture bash -c "dd if=/dev/zero of='$testfile' bs=1M count=${mib_count} conv=fdatasync status=progress")"
  # Extract last MB/s figure
  SUMMARY_DD_WRITE="$(echo "$write_out" | awk '/copied,/ {print $(NF-1), $NF}' | tail -n1)"
  [[ -z "$SUMMARY_DD_WRITE" ]] && SUMMARY_DD_WRITE="N/A"

  # Drop page cache on client for read test (requires root)
  if [[ -n "${SUDO:-}" ]]; then
    echo -e "\n-- Dropping client page cache (sudo required) --" | tee_log
    echo "3" | $SUDO tee /proc/sys/vm/drop_caches >/dev/null || true
  else
    warn "Skipping drop_caches (not running with sudo); read test may be affected by client cache."
  fi

  # Read test
  echo -e "\n-- Read test: dd if=$testfile of=/dev/null bs=1M --" | tee_log
  local read_out
  read_out="$(run_capture bash -c "dd if='$testfile' of=/dev/null bs=1M status=progress")"
  SUMMARY_DD_READ="$(echo "$read_out" | awk '/copied,/ {print $(NF-1), $NF}' | tail -n1)"
  [[ -z "$SUMMARY_DD_READ" ]] && SUMMARY_DD_READ="N/A"

  ANY_TEST_RAN=1
}

# ----------------------------- fio tests -----------------------------
FIO_TIME_DEFAULT=60
fio_throughput() {
  local dur="${1:-$FIO_TIME_DEFAULT}"
  echo -e "\n=== fio Sequential Throughput (1MiB blocks, ${dur}s) ===" | tee_log
  local out
  out="$(run_capture fio --name=seq_rw --directory="$TEST_DIR" \
    --size=2G --bs=1M --rw=readwrite --rwmixread=70 \
    --numjobs=1 --time_based=1 --runtime="$dur" --group_reporting \
    --direct=0 --invalidate=1 --ioengine=psync)"
  # Parse BW for read/write:
  # Expect lines like:  read: IOPS=..., BW=123MiB/s ...  write: IOPS=..., BW=45.6MiB/s ...
  local r w
  r="$(echo "$out" | awk '/\bread: .*BW=/{for(i=1;i<=NF;i++) if($i ~ /^BW=/){gsub("BW=","",$i); print $i}}' | tail -n1)"
  w="$(echo "$out" | awk '/\bwrite: .*BW=/{for(i=1;i<=NF;i++) if($i ~ /^BW=/){gsub("BW=","",$i); print $i}}' | tail -n1)"
  [[ -n "$r" ]] && SUMMARY_FIO_SEQ_READ="$r" || SUMMARY_FIO_SEQ_READ="N/A"
  [[ -n "$w" ]] && SUMMARY_FIO_SEQ_WRITE="$w" || SUMMARY_FIO_SEQ_WRITE="N/A"
  ANY_TEST_RAN=1
}

fio_iops() {
  local dur="${1:-$FIO_TIME_DEFAULT}"
  echo -e "\n=== fio Random IOPS (4k blocks, ${dur}s) ===" | tee_log
  local out
  out="$(run_capture fio --name=rand_rw --directory="$TEST_DIR" \
    --size=2G --bs=4k --rw=randrw --rwmixread=70 \
    --iodepth=16 --numjobs=1 --time_based=1 --runtime="$dur" --group_reporting \
    --direct=0 --invalidate=1 --ioengine=psync)"
  # Parse IOPS for read/write
  local r w
  r="$(echo "$out" | awk '/\bread: IOPS=/{for(i=1;i<=NF;i++) if($i ~ /^IOPS=/){gsub("IOPS=","",$i); print $i}}' | tail -n1)"
  w="$(echo "$out" | awk '/\bwrite: IOPS=/{for(i=1;i<=NF;i++) if($i ~ /^IOPS=/){gsub("IOPS=","",$i); print $i}}' | tail -n1)"
  [[ -n "$r" ]] && SUMMARY_FIO_RAND_RIOPS="$r" || SUMMARY_FIO_RAND_RIOPS="N/A"
  [[ -n "$w" ]] && SUMMARY_FIO_RAND_WIOPS="$w" || SUMMARY_FIO_RAND_WIOPS="N/A"
  ANY_TEST_RAN=1
}

# ----------------------------- iperf3 -----------------------------
iperf_menu() {
  echo -e "\n=== iperf3 Network Test ===" | tee_log
  cat <<EOF
You have two options:
  1) Run iperf3 SERVER on this Ubuntu machine, then from another host (e.g., NAS or another PC):
       iperf3 -c <this_ubuntu_ip>
  2) Run iperf3 CLIENT from this Ubuntu machine to a host running server:
       iperf3 -s              # (run on the other host)
       iperf3 -c <server_ip>  # (run here)
EOF
  echo -n "Choose [1=Server here, 2=Client here, 0=Back]: "
  read -r c
  case "$c" in
    1)
      echo "Starting iperf3 server (Ctrl+C to stop)..." | tee_log
      run_and_log iperf3 -s
      ;;
    2)
      echo -n "Enter iperf3 server IP/hostname: "; read -r srv
      local out
      out="$(run_capture iperf3 -c "$srv")"
      # Parse sender/receiver bandwidth Mbps/Gbps (prefer receiver line)
      local bw
      bw="$(echo "$out" | awk '/receiver/{bw=$(NF-1)" " $NF} END{print bw}')"
      [[ -z "$bw" ]] && bw="$(echo "$out" | awk '/sender/{bw=$(NF-1)" " $NF} END{print bw}')"
      [[ -n "$bw" ]] && SUMMARY_IPERF="$bw" || SUMMARY_IPERF="N/A"
      ANY_TEST_RAN=1
      ;;
    *) ;;
  esac
}

# ----------------------------- Cleanup -----------------------------
cleanup_files() {
  echo -e "\n=== Cleanup Test Files ===" | tee_log
  if [[ -d "$TEST_DIR" ]]; then
    du -sh "$TEST_DIR" 2>/dev/null | tee_log || true
    echo -n "Delete test directory $TEST_DIR ? [y/N]: "
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      need_sudo
      run_and_log $SUDO rm -rf "$TEST_DIR"
      ok "Removed $TEST_DIR"
    else
      warn "Skipping cleanup."
    fi
  else
    warn "No test directory found: $TEST_DIR"
  fi
}

# ----------------------------- Summary -----------------------------
print_clean_summary() {
  cat <<EOT
================== BENCHMARK SUMMARY (v${VERSION}) ==================
Test                     | Result
--------------------------------------------------------
dd Write (${DD_SIZE_DEFAULT})        | ${SUMMARY_DD_WRITE}
dd Read  (${DD_SIZE_DEFAULT})        | ${SUMMARY_DD_READ}
fio Seq Throughput         | Read: ${SUMMARY_FIO_SEQ_READ}, Write: ${SUMMARY_FIO_SEQ_WRITE}
fio Random IOPS (4k)       | Read: ${SUMMARY_FIO_RAND_RIOPS}, Write: ${SUMMARY_FIO_RAND_WIOPS}
iperf3 Network             | ${SUMMARY_IPERF}
========================================================
Detailed log: ${LOG_FILE}
EOT
}

write_summary_file() {
  {
    echo "NFS NAS Benchmark Summary (v${VERSION})"
    echo "Timestamp: ${TIMESTAMP}"
    echo "Mountpoint: ${MOUNTPOINT}"
    echo "Log file: ${LOG_FILE}"
    echo
    echo "Results:"
    echo "  dd Write (${DD_SIZE_DEFAULT}): ${SUMMARY_DD_WRITE}"
    echo "  dd Read  (${DD_SIZE_DEFAULT}): ${SUMMARY_DD_READ}"
    echo "  fio Seq Throughput: Read ${SUMMARY_FIO_SEQ_READ}, Write ${SUMMARY_FIO_SEQ_WRITE}"
    echo "  fio Random IOPS (4k): Read ${SUMMARY_FIO_RAND_RIOPS}, Write ${SUMMARY_FIO_RAND_WIOPS}"
    echo "  iperf3: ${SUMMARY_IPERF}"
  } > "${SUMMARY_FILE}"
}

# ----------------------------- Orchestrations -----------------------------
full_suite() {
  show_diagnostics
  dd_tests "$DD_SIZE_DEFAULT"
  fio_throughput "$FIO_TIME_DEFAULT"
  fio_iops "$FIO_TIME_DEFAULT"
  ANY_TEST_RAN=1
  echo
  print_clean_summary | tee_log
}

# ----------------------------- Main Menu -----------------------------
on_exit() {
  # Upon exit, always write the clean summary file (even if tests didn't run)
  write_summary_file
  echo
  echo "Summary saved to: ${SUMMARY_FILE}"
  echo "Full detailed log: ${LOG_FILE}"
}
trap on_exit EXIT

main_menu() {
  while true; do
    echo -e "\n${BOLD}NFS NAS Benchmark Toolkit v${VERSION}${RESET}"
    echo "Mountpoint: $MOUNTPOINT"
    echo "Test dir:   $TEST_DIR"
    echo "Log file:   $LOG_FILE"
    cat <<MENU

[1] Diagnostics (NFS mount & network)
[2] dd sequential write/read (size=${DD_SIZE_DEFAULT})
[3] fio sequential throughput (1MiB, ${FIO_TIME_DEFAULT}s)
[4] fio random IOPS (4k, ${FIO_TIME_DEFAULT}s)
[5] iperf3 network test
[6] Cleanup test files
[7] Run FULL suite (1→4)
[0] Exit
MENU
    echo -n "Select: "
    read -r opt
    case "$opt" in
      1) show_diagnostics ;;
      2) echo -n "Enter file size (e.g., 1G, 2G) [${DD_SIZE_DEFAULT}]: "; read -r sz; sz=${sz:-$DD_SIZE_DEFAULT}; dd_tests "$sz" ;;
      3) echo -n "Duration in seconds [${FIO_TIME_DEFAULT}]: "; read -r d; d=${d:-$FIO_TIME_DEFAULT}; fio_throughput "$d" ;;
      4) echo -n "Duration in seconds [${FIO_TIME_DEFAULT}]: "; read -r d; d=${d:-$FIO_TIME_DEFAULT}; fio_iops "$d" ;;
      5) iperf_menu ;;
      6) cleanup_files ;;
      7) full_suite ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# ----------------------------- Bootstrap -----------------------------
echo "Log file: $LOG_FILE"
install_deps
choose_mountpoint
main_menu
