#!/usr/bin/env bash
#
# offline_patch.sh
#
# Individual-server offline patch management for supported Enterprise Linux hosts.
# Uses DNF4. The local repository remains on the same server.
#
# Usage:
#   sudo ./offline_patch.sh download
#   sudo ./offline_patch.sh install
#   sudo reboot
#   sudo ./offline_patch.sh verify
#   sudo ./offline_patch.sh report
#
# IMPORTANT:
#   Change DNS_TEST_NAME to a hostname that should resolve in your environment.
#   For an internal-only network, use an internal FQDN instead of rockylinux.org.
#

set -Eeuo pipefail
umask 077

# ----------------------------- Configuration -----------------------------

BASE_DIR="/usr/local/src"
STATE_BASE="/var/lib/offline-patching"
LOCK_FILE="/var/lock/offline_patch.lock"

REPO_ID="offline-local"

# Set this to a hostname resolvable in your environment.
# For example: "your-internal-repo.company.example"
DNS_TEST_NAME="rockylinux.org"

# Rocky Linux 10 support remains disabled until its full workflow has been
# validated on a Rocky 10 test host. Set to "yes" only after that validation.
ENABLE_ROCKY_10="no"

# Optional MinIO alias configured for the root account with `mc alias set`.
# When set, the script exports server settings, IAM, and bucket metadata.
MINIO_ALIAS=""

CONNECTIVITY_ATTEMPTS=3
CONNECTIVITY_RETRY_DELAY=10
DNF_TIMEOUT=30
DNF_RETRIES=2
DOWNLOAD_SPACE_BUFFER_PERCENT=30
MIN_REPO_FREE_BYTES=1073741824
MIN_STATE_FREE_BYTES=536870912

# -------------------------------------------------------------------------

SCRIPT_VERSION="1.0.0"
HOST="$(hostname -s)"
DATE_TAG="$(date +%Y%m%d_%H%M%S)"
RUN_ID=""
ACTIVE_STATE=""
CURRENT_COMMAND=""
CURRENT_PHASE="initialization"
OS_ID=""
OS_VERSION_ID=""
OS_MAJOR=""
ARCH="$(uname -m)"

# ----------------------------- Common helpers -----------------------------

log() {
    echo "[$(date '+%F %T')] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root using sudo."
}

require_persistent_session() {
    if [[ -n "${STY:-}" ]]; then
        log "Running inside GNU screen session: ${STY}"
        return 0
    fi
    if [[ -n "${TMUX:-}" ]]; then
        log "Running inside tmux session: ${TMUX}"
        return 0
    fi
    die "Run '$0 $1' inside GNU screen or tmux so the session survives an SSH disconnect. Start screen/tmux, reconnect to it, then rerun this command."
}

check_commands() {
    local cmd
    for cmd in dnf rpm sha256sum awk sed grep sort comm hostname stat tar \
               getent timeout flock date find basename readlink cp chmod \
               chown cat wc tr sleep xargs paste cmp ip df lsblk findmnt systemctl diff mv rmdir; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command not found: $cmd"
    done
}

available_bytes() {
    local path="$1"
    df -B1 --output=avail "$path" 2>/dev/null | awk 'NR == 2 {print $1}'
}

fail_download_preflight() {
    local state="$1" message="$2"
    set_value "$state/status" "FAILED"
    set_value "$state/failed_phase" "$CURRENT_PHASE"
    set_value "$state/failed_at" "$(date '+%F %T %Z')"
    set_value "$state/error" "$message"
    generate_report "$state"
    ACTIVE_STATE=""
    die "$message"
}

check_download_space() {
    local state="$1" repo_dir="$2" estimate_output estimate_bytes
    local repo_available state_available repo_required

    log "Estimating the upgrade download size and checking free space..."
    estimate_output="$(LC_ALL=C dnf \
        --setopt=skip_if_unavailable=False \
        --setopt=retries="$DNF_RETRIES" \
        --setopt=timeout="$DNF_TIMEOUT" \
        upgrade --assumeno 2>&1 || true)"
    printf '%s\n' "$estimate_output" > "$state/dnf_space_estimate.txt"

    estimate_bytes="$(awk '
        /^Total download size:/ {
            amount=$(NF-1); unit=$NF; gsub(/,/, "", amount)
            factor=1
            if (unit ~ /^[kK]([bB])?$/) factor=1024
            else if (unit ~ /^[mM]([bB])?$/) factor=1024^2
            else if (unit ~ /^[gG]([bB])?$/) factor=1024^3
            else if (unit ~ /^[tT]([bB])?$/) factor=1024^4
            else if (unit !~ /^[bB]$/) exit 1
            printf "%.0f\n", amount * factor
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' <<< "$estimate_output" 2>/dev/null || true)"
    if [[ -z "$estimate_bytes" ]] && grep -Fqi "Nothing to do" <<< "$estimate_output"; then
        estimate_bytes=0
    fi
    if [[ ! "$estimate_bytes" =~ ^[0-9]+$ ]]; then
        set_value "$state/download_space_preflight_status" "FAILED"
        fail_download_preflight "$state" "Could not estimate the DNF upgrade download size. Review $state/dnf_space_estimate.txt; no packages were downloaded."
    fi

    repo_available="$(available_bytes "$repo_dir")"
    state_available="$(available_bytes "$state")"
    if [[ ! "$repo_available" =~ ^[0-9]+$ || ! "$state_available" =~ ^[0-9]+$ ]]; then
        set_value "$state/download_space_preflight_status" "FAILED"
        fail_download_preflight "$state" "Could not determine available space for the package repository or run-state filesystem."
    fi

    repo_required=$((estimate_bytes + estimate_bytes * DOWNLOAD_SPACE_BUFFER_PERCENT / 100 + MIN_REPO_FREE_BYTES))
    set_value "$state/download_size_estimate_bytes" "$estimate_bytes"
    set_value "$state/repository_space_available_bytes" "$repo_available"
    set_value "$state/repository_space_required_bytes" "$repo_required"
    set_value "$state/state_space_available_bytes" "$state_available"
    set_value "$state/state_space_required_bytes" "$MIN_STATE_FREE_BYTES"

    {
        echo "Package repository path: $repo_dir"
        echo "Package repository filesystem available bytes: $repo_available"
        echo "Estimated package download bytes: $estimate_bytes"
        echo "Repository free space required bytes (estimate + ${DOWNLOAD_SPACE_BUFFER_PERCENT}% buffer + reserve): $repo_required"
        echo "Run-state path: $state"
        echo "Run-state filesystem available bytes: $state_available"
        echo "Run-state free space required bytes: $MIN_STATE_FREE_BYTES"
    } > "$state/download_space_preflight.txt"

    if ((repo_available < repo_required)); then
        set_value "$state/download_space_preflight_status" "FAILED"
        fail_download_preflight "$state" "Insufficient free space on the filesystem containing $repo_dir: available $repo_available bytes; required $repo_required bytes. See $state/download_space_preflight.txt."
    fi
    if ((state_available < MIN_STATE_FREE_BYTES)); then
        set_value "$state/download_space_preflight_status" "FAILED"
        fail_download_preflight "$state" "Insufficient free space on the filesystem containing $state: available $state_available bytes; required $MIN_STATE_FREE_BYTES bytes. See $state/download_space_preflight.txt."
    fi

    set_value "$state/download_space_preflight_status" "PASSED"
    log "Space preflight passed: estimated download $estimate_bytes bytes; repository available $repo_available bytes; run-state available $state_available bytes."
}

# ----------------------------- Local configuration backup ----------------

backup_configs() {
    local state="$1"
    local backup_dir
    local manifest_hash
    local config_path
    local -a config_paths=()

    if [[ -n "$(get_value "$state/config_backup_dir")" ]]; then
        backup_dir="$state/linux-recovery-baseline-$(date +%Y%m%d_%H%M%S)_$$"
    else
        backup_dir="$state/linux-baseline"
    fi

    mkdir -m 700 -p "$backup_dir"
    chmod 700 "$backup_dir"

    log "Capturing Linux host, network, storage, and boot baseline..."
    for config_path in /etc/hostname /etc/hosts /etc/fstab /etc/crypttab \
        /etc/resolv.conf /etc/sysctl.conf /etc/sysctl.d \
        /etc/NetworkManager /etc/sysconfig/network-scripts \
        /etc/systemd/network /etc/udev/rules.d /etc/modprobe.d \
        /etc/firewalld; do
        [[ -e "$config_path" ]] && config_paths+=("${config_path#/}")
    done
    if ((${#config_paths[@]})); then
        tar --acls --xattrs --selinux --numeric-owner \
            -czf "$backup_dir/linux-config.tar.gz" -C / "${config_paths[@]}"
        tar -tzf "$backup_dir/linux-config.tar.gz" >/dev/null
        chmod 600 "$backup_dir/linux-config.tar.gz"
    fi
    collect_linux_snapshot "$backup_dir" before

    (
        cd "$backup_dir"
        find . -type f ! -name SHA256SUMS ! -path './post/*' -print0 |
            sort -z |
            xargs -0 -r sha256sum > SHA256SUMS
        sha256sum --check SHA256SUMS >/dev/null
    )
    chmod 600 "$backup_dir/SHA256SUMS"
    manifest_hash="$(sha256sum "$backup_dir/SHA256SUMS" | awk '{print $1}')"

    if [[ "$backup_dir" == "$state/linux-baseline" ]]; then
        set_value "$state/config_backup_dir" "$backup_dir"
        set_value "$state/config_backup_manifest_hash" "$manifest_hash"
        set_value "$state/config_backup_created" "$(date '+%F %T %Z')"
        set_value "$state/config_backup_status" "PASSED"
    else
        set_value "$state/recovery_linux_baseline_dir" "$backup_dir"
    fi
    log "Linux pre-patch baseline captured and verified: $backup_dir"
}

collect_linux_snapshot() {
    local backup_dir="$1" phase="$2" output="$1/$2"
    mkdir -p "$output"
    chmod 700 "$output"
    {
        echo "Captured: $(date '+%F %T %Z')"
        echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
        echo "Kernel: $(uname -r)"
        echo "Boot ID: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        echo "OS: $(. /etc/os-release; printf '%s %s' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}")"
    } > "$output/host.txt"
    df -hT > "$output/df-hT.txt" 2>&1 || true
    lsblk -a -o NAME,KNAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS > "$output/lsblk.txt" 2>&1 || lsblk -a > "$output/lsblk.txt" 2>&1 || true
    findmnt --real > "$output/findmnt.txt" 2>&1 || mount > "$output/mounts.txt" 2>&1 || true
    ip -brief address > "$output/ip-address.txt" 2>&1 || true
    ip route show table all > "$output/ip-routes.txt" 2>&1 || true
    ip rule show > "$output/ip-rules.txt" 2>&1 || true
    ip -6 route show table all > "$output/ip6-routes.txt" 2>&1 || true
    if command -v nmcli >/dev/null 2>&1; then
        nmcli -f GENERAL,IP4,IP6 device show > "$output/nmcli-devices.txt" 2>&1 || true
        nmcli connection show --active > "$output/nmcli-active-connections.txt" 2>&1 || true
    fi
    systemctl --failed --no-legend > "$output/failed-services.txt" 2>&1 || true
    systemctl get-default > "$output/systemd-default-target.txt" 2>&1 || true
    chmod 600 "$output"/* 2>/dev/null || true
}

get_os_info() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_MAJOR="${OS_VERSION_ID%%.*}"

    case "$OS_ID" in
        rocky|rhel|almalinux|ol)
            ;;
        *)
            die "Unsupported OS ID: $OS_ID. Supported: Rocky, RHEL, AlmaLinux, Oracle Linux."
            ;;
    esac

    case "$OS_MAJOR" in
        8|9)
            ;;
        10)
            [[ "$OS_ID" == "rocky" ]] ||
                die "Major version 10 is currently supported only for Rocky Linux."
            [[ "$ENABLE_ROCKY_10" == "yes" ]] ||
                die "Rocky Linux 10 support is currently gated off. Validate the full workflow on a Rocky 10 test host, then set ENABLE_ROCKY_10=\"yes\" near the top of this script."
            ;;
        *)
            die "Unsupported OS major version: $OS_MAJOR. This script targets versions 8 and 9, with gated Rocky Linux 10 support."
            ;;
    esac
}

validate_rocky10_environment() {
    local dnf_version loader_help

    [[ "$OS_ID" == "rocky" && "$OS_MAJOR" == "10" ]] || return 0

    dnf_version="$(dnf --version 2>&1 | sed -n '1p')"
    [[ "$dnf_version" =~ ^4([.]|$) ]] ||
        die "Rocky Linux 10 support requires DNF4; detected: ${dnf_version:-unknown}. DNF5 has not been validated by this script."

    if [[ "$ARCH" == "x86_64" ]]; then
        [[ -x /lib64/ld-linux-x86-64.so.2 ]] ||
            die "Cannot locate the x86_64 dynamic loader to verify the x86-64-v3 CPU baseline."
        loader_help="$(/lib64/ld-linux-x86-64.so.2 --help 2>&1)"
        grep -Eq 'x86-64-v3 \(supported, searched\)' <<< "$loader_help" ||
            die "CPU or virtual machine does not expose the x86-64-v3 capability required by Rocky Linux 10."
    fi
}

get_admin() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        id -un
    fi
}

get_state_dirs() {
    local status_filter="${1:-}"
    local dir status

    [[ -d "$STATE_BASE/$HOST" ]] || return 0

    while IFS= read -r -d '' dir; do
        status="$(get_value "$dir/status")"
        if [[ -z "$status_filter" || "$status" == "$status_filter" ]]; then
            printf '%s\n' "$dir"
        fi
    done < <(find "$STATE_BASE/$HOST" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

get_value() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    cat "$file"
}

set_value() {
    local file="$1"
    local value="$2"
    printf '%s\n' "$value" > "$file"
}

select_state() {
    local filter="$1"
    local prompt="${2:-Select a patch run}"
    local -a states=()
    local i choice status run

    while IFS= read -r state; do
        [[ -n "$state" ]] && states+=("$state")
    done < <(get_state_dirs "$filter")

    (("${#states[@]}" > 0)) ||
        die "No patch runs found with status: ${filter:-any}."

    if (("${#states[@]}" == 1)); then
        echo "${states[0]}"
        return 0
    fi

    echo >&2
    echo "$prompt" >&2
    echo "-----------------------------------------------" >&2

    for i in "${!states[@]}"; do
        status="$(get_value "${states[$i]}/status")"
        run="$(basename "${states[$i]}")"
        printf '%d) %-25s Status: %s\n' \
            "$((i + 1))" "$run" "$status" >&2
    done

    echo >&2
    read -r -p "Enter selection: " choice

    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid selection."
    ((choice >= 1 && choice <= ${#states[@]})) ||
        die "Selection out of range."

    echo "${states[$((choice - 1))]}"
}

handle_error() {
    local rc="$1"
    local line="$2"

    trap - ERR
    set +e

    if [[ -n "${ACTIVE_STATE:-}" && -d "$ACTIVE_STATE" ]]; then
        local status
        status="$(get_value "$ACTIVE_STATE/status")"

        if [[ "$status" == "DOWNLOADING" || "$status" == "INSTALLING" || "$status" == "VERIFYING" ]]; then
            set_value "$ACTIVE_STATE/status" "FAILED"
            set_value "$ACTIVE_STATE/error" "Command failed at line $line with exit code $rc"
            set_value "$ACTIVE_STATE/failed_phase" "$CURRENT_PHASE"
            set_value "$ACTIVE_STATE/failed_at" "$(date '+%F %T %Z')"
        fi
    fi

    log "ERROR: Script failed at line $line (exit code $rc)."
    exit "$rc"
}

cleanup() {
    :
}

# ----------------------------- Locking ------------------------------------

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another offline_patch.sh process is already running."
}

# ----------------------------- DNF connectivity ---------------------------

check_repository_connectivity() {
    local attempt

    log "Checking enabled DNF repositories..."

    dnf repolist --enabled ||
        die "Unable to list enabled DNF repositories. Check repository configuration."

    for ((attempt = 1; attempt <= CONNECTIVITY_ATTEMPTS; attempt++)); do
        log "Repository connectivity test: attempt $attempt/$CONNECTIVITY_ATTEMPTS"

        if dnf \
            --setopt=skip_if_unavailable=False \
            --setopt=retries="$DNF_RETRIES" \
            --setopt=timeout="$DNF_TIMEOUT" \
            makecache --refresh; then
            log "All enabled repositories passed the DNF metadata refresh."
            return 0
        fi

        if ((attempt < CONNECTIVITY_ATTEMPTS)); then
            log "Repository metadata refresh failed. Retrying in ${CONNECTIVITY_RETRY_DELAY}s..."
            sleep "$CONNECTIVITY_RETRY_DELAY"
        fi
    done

    cat <<'EOF'

Repository connectivity validation FAILED.

The script will not continue and will not modify repository, proxy,
subscription, or DNS configuration automatically.

Possible causes:
  1. DNS resolution failure.
  2. Network routing or firewall restrictions.
  3. Proxy configuration problems.
  4. Internal mirror or Satellite server unavailable.
  5. Invalid repository URL or credentials.
  6. Subscription or repository entitlement issues.

Check:
  dnf repolist --enabled
  dnf makecache --refresh
  cat /etc/resolv.conf
  getent hosts <repository-hostname>

Resolve the repository issue and run the download command again.
EOF

    return 1
}

# ----------------------------- DNS backup/restore -------------------------

backup_dns() {
    local state="$1"
    local dns_file="/etc/resolv.conf"
    local real_file mode uid gid

    [[ -e "$dns_file" ]] || die "$dns_file does not exist."

    real_file="$(readlink -f "$dns_file")"
    [[ -n "$real_file" && -f "$real_file" ]] ||
        die "Unable to resolve the actual $dns_file target."

    mode="$(stat -Lc '%a' "$dns_file")"
    uid="$(stat -Lc '%u' "$dns_file")"
    gid="$(stat -Lc '%g' "$dns_file")"

    cp -L "$dns_file" "$state/resolv.conf.backup"

    set_value "$state/dns_original_target" "$real_file"
    set_value "$state/dns_original_mode" "$mode"
    set_value "$state/dns_original_uid" "$uid"
    set_value "$state/dns_original_gid" "$gid"
    set_value "$state/dns_backup_created" "YES"

    log "DNS configuration backed up."
}

restore_dns() {
    local state="$1"
    local backup="$state/resolv.conf.backup"
    local mode uid gid

    [[ -s "$backup" ]] || {
        log "DNS backup is missing or empty."
        return 1
    }

    mode="$(get_value "$state/dns_original_mode")"
    uid="$(get_value "$state/dns_original_uid")"
    gid="$(get_value "$state/dns_original_gid")"

    [[ -n "$mode" && -n "$uid" && -n "$gid" ]] || {
        log "DNS backup metadata is incomplete."
        return 1
    }

    # Write through /etc/resolv.conf. If it is a symlink, this normally
    # writes to its current target rather than replacing the symlink.
    if ! cat "$backup" > /etc/resolv.conf; then
        log "Unable to write the DNS backup to /etc/resolv.conf."
        return 1
    fi

    chmod "$mode" /etc/resolv.conf || return 1
    chown "$uid:$gid" /etc/resolv.conf || return 1

    if ! cmp -s "$backup" /etc/resolv.conf; then
        log "DNS content does not match the saved backup."
        return 1
    fi

    set_value "$state/dns_restored" "YES"
    log "DNS configuration restored and content comparison passed."
    return 0
}

# ----------------------------- Repository integrity -----------------------

validate_repository() {
    local state="$1"
    local repo_dir="$2"

    [[ -d "$repo_dir" ]] || die "Local repository directory is missing: $repo_dir"
    [[ -s "$repo_dir/SHA256SUMS" ]] || die "SHA256SUMS manifest is missing."

    log "Validating local repository checksums..."

    (
        cd "$repo_dir"
        sha256sum --check SHA256SUMS
    ) || die "Repository checksum validation failed."

    log "Repository checksum validation passed."
}

# ----------------------------- RPM inventory ------------------------------

capture_rpm_inventory() {
    local output_file="$1"

    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' |
        sort > "$output_file"
}

html_escape() {
    printf '%s' "$1" | sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

html_escape_file() {
    sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        "$1"
}

generate_html_report() {
    local state="$1" report="$1/patch_execution_report.html"
    local baseline_dir before_file after_file name value

    baseline_dir="$(get_value "$state/config_backup_dir")"
    {
        cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Linux Patch Report</title>
<style>
body{font:15px/1.5 system-ui,sans-serif;max-width:1200px;margin:2rem auto;padding:0 1rem;color:#1f2937}
h1,h2{color:#111827}table{border-collapse:collapse;width:100%;margin:1rem 0 2rem}th,td{border:1px solid #d1d5db;padding:.5rem;text-align:left;vertical-align:top}th{background:#f3f4f6}
pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f8fafc;padding:1rem;border:1px solid #e5e7eb;border-radius:.35rem;margin:.5rem 0}
.columns{display:grid;grid-template-columns:1fr 1fr;gap:1rem}details{margin:1rem 0}summary{cursor:pointer;font-weight:600}.note{color:#4b5563}
@media(max-width:760px){.columns{grid-template-columns:1fr}}
</style>
</head>
<body>
<h1>Linux Patch Report</h1>
HTML
        printf '<table><tbody>\n'
        for name in Hostname Run_ID Lifecycle_status Verification_status Space_preflight \
            Upgrade_size_estimate_bytes Repository_space_available_bytes \
            Repository_space_required_bytes State_space_available_bytes \
            Install_started Install_completed Verification_completed; do
            case "$name" in
                Hostname) value="$HOST" ;;
                Run_ID) value="$(basename "$state")" ;;
                Lifecycle_status) value="$(get_value "$state/status")" ;;
                Verification_status) value="$(get_value "$state/verification_status")" ;;
                Space_preflight) value="$(get_value "$state/download_space_preflight_status")" ;;
                Upgrade_size_estimate_bytes) value="$(get_value "$state/download_size_estimate_bytes")" ;;
                Repository_space_available_bytes) value="$(get_value "$state/repository_space_available_bytes")" ;;
                Repository_space_required_bytes) value="$(get_value "$state/repository_space_required_bytes")" ;;
                State_space_available_bytes) value="$(get_value "$state/state_space_available_bytes")" ;;
                Install_started) value="$(get_value "$state/install_started")" ;;
                Install_completed) value="$(get_value "$state/install_completed")" ;;
                Verification_completed) value="$(get_value "$state/verification_completed")" ;;
            esac
            printf '<tr><th>%s</th><td>%s</td></tr>\n' \
                "$(html_escape "${name//_/ }")" "$(html_escape "$value")"
        done
        printf '</tbody></table>\n'
        printf '<h2>Pre and post reboot snapshots</h2>\n'
        printf '<p class="note">Differences can reflect expected package updates and dynamic system state. Review them; they are not automatic pass/fail checks.</p>\n'
        if [[ -d "$baseline_dir/before" ]]; then
            for before_file in "$baseline_dir"/before/*; do
                [[ -f "$before_file" ]] || continue
                name="$(basename "$before_file")"
                after_file="$baseline_dir/post/$name"
                printf '<details open><summary>%s</summary><div class="columns">' "$(html_escape "$name")"
                printf '<section><h3>Before patch</h3><pre>'
                html_escape_file "$before_file"
                printf '</pre></section><section><h3>After reboot</h3><pre>'
                if [[ -f "$after_file" ]]; then
                    html_escape_file "$after_file"
                else
                    printf 'Post-reboot snapshot not captured yet.'
                fi
                printf '</pre></section></div></details>\n'
            done
        else
            printf '<p>Linux pre-patch snapshot is not available.</p>\n'
        fi
        printf '<h2>Comparison diff</h2>\n'
        if [[ -s "$state/linux_baseline_diff.txt" ]]; then
            printf '<pre>'
            html_escape_file "$state/linux_baseline_diff.txt"
            printf '</pre>\n'
        else
            printf '<p>Post-reboot comparison is not available yet.</p>\n'
        fi
        printf '<h2>Verification details</h2>\n'
        if [[ -s "$state/verification_details.txt" ]]; then
            printf '<pre>'
            html_escape_file "$state/verification_details.txt"
            printf '</pre>\n'
        else
            printf '<p>Verification has not been run.</p>\n'
        fi
        printf '</body></html>\n'
    } > "$report"
    chmod 600 "$report"
}

# ----------------------------- Report generation --------------------------

generate_report() {
    local state="$1"
    local report="$state/patch_execution_report.txt"

    {
        echo "=============================================================="
        echo "                 PATCH EXECUTION REPORT"
        echo "=============================================================="
        echo
        echo "Script version          : $SCRIPT_VERSION"
        echo "Hostname                : $HOST"
        echo "Run ID                  : $(basename "$state")"
        echo "Lifecycle status        : $(get_value "$state/status")"
        echo "Failed phase            : $(get_value "$state/failed_phase")"
        echo "Failure time            : $(get_value "$state/failed_at")"
        echo "Error                   : $(get_value "$state/error")"
        echo "Download admin          : $(get_value "$state/download_admin")"
        echo "Install admin           : $(get_value "$state/install_admin")"
        echo "Verification admin      : $(get_value "$state/verification_admin")"
        echo
        echo "---------------------- Operating System ---------------------"
        echo "OS ID                   : $(get_value "$state/os_id")"
        echo "OS version at download  : $(get_value "$state/os_version_id")"
        echo "OS major version        : $(get_value "$state/os_major")"
        echo "Architecture            : $(get_value "$state/arch")"
        echo
        echo "---------------------- Patch Repository ---------------------"
        echo "Repository path         : $(get_value "$state/repo_dir")"
        echo "RPM count               : $(get_value "$state/rpm_count")"
        echo "Repository checksum     : $(get_value "$state/repository_checksum_status")"
        echo "Space preflight         : $(get_value "$state/download_space_preflight_status")"
        echo "Upgrade size estimate   : $(get_value "$state/download_size_estimate_bytes") bytes"
        echo "Repository space avail  : $(get_value "$state/repository_space_available_bytes") bytes"
        echo "Repository space need   : $(get_value "$state/repository_space_required_bytes") bytes"
        echo "State space available   : $(get_value "$state/state_space_available_bytes") bytes"
        echo
        echo "---------------------- Installation -------------------------"
        echo "Install started         : $(get_value "$state/install_started")"
        echo "Install completed       : $(get_value "$state/install_completed")"
        echo "Linux baseline status   : $(get_value "$state/config_backup_status")"
        echo "Linux baseline path     : $(get_value "$state/config_backup_dir")"
        echo "Recovery baseline path  : $(get_value "$state/recovery_linux_baseline_dir")"
        echo "External copy confirmed : $(get_value "$state/config_backup_copy_confirmed")"
        echo "Recovery started        : $(get_value "$state/recovery_started")"
        echo "Recovery completed      : $(get_value "$state/recovery_completed")"
        echo "Recovery result         : $(get_value "$state/recovery_result")"
        echo "DNF transaction ID      : $(get_value "$state/dnf_transaction_id")"
        echo "Kernel before install   : $(get_value "$state/kernel_before_install")"
        echo "Kernel after install    : $(get_value "$state/kernel_after_install")"
        echo "Expected boot kernel    : $(get_value "$state/kernel_expected")"
        echo
        echo "Package changes:"
        if [[ -s "$state/package_changes.txt" ]]; then
            cat "$state/package_changes.txt"
        else
            echo "No package changes recorded."
        fi
        echo
        echo "---------------------- Post-Reboot Verification -------------"
        echo "Verification status     : $(get_value "$state/verification_status")"
        echo "Verification attempt    : $(get_value "$state/verification_attempt_time")"
        echo "Verification completed  : $(get_value "$state/verification_completed")"
        echo "Reboot detected         : $(get_value "$state/reboot_status")"
        echo "Boot ID before install  : $(get_value "$state/boot_id_before_install")"
        echo "Boot ID after reboot    : $(get_value "$state/boot_id_after_reboot")"
        echo "Running kernel          : $(get_value "$state/kernel_after_reboot")"
        echo "Kernel validation       : $(get_value "$state/kernel_validation")"
        echo "OS validation           : $(get_value "$state/os_validation")"
        echo "DNF transaction check   : $(get_value "$state/dnf_transaction_validation")"
        echo "DNS restoration         : $(get_value "$state/dns_restored")"
        echo "DNS nameserver          : $(get_value "$state/dns_nameserver")"
        echo "DNS search domain       : $(get_value "$state/dns_search")"
        echo "DNS resolution test     : $(get_value "$state/dns_resolution_status")"
        echo "DNS test hostname       : $(get_value "$state/dns_test_name")"
        echo
        echo "Verification failures:"
        if [[ -s "$state/verification_failures.txt" ]]; then
            cat "$state/verification_failures.txt"
        else
            echo "None recorded."
        fi
        echo
        echo "---------------------- Supporting Files ---------------------"
        echo "RPM inventory           : $state/rpm_inventory.txt"
        echo "Space preflight details : $state/download_space_preflight.txt"
        echo "DNF size estimate       : $state/dnf_space_estimate.txt"
        echo "Linux baseline         : $(get_value "$state/config_backup_dir")"
        echo "Linux baseline diff    : $(get_value "$state/linux_baseline_diff")"
        echo "HTML report             : $state/patch_execution_report.html"
        echo "Package changes         : $state/package_changes.txt"
        echo "DNF transaction details : $state/dnf_history_info.txt"
        echo "Verification details    : $state/verification_details.txt"
        echo
        echo "=============================================================="
        echo "Generated: $(date '+%F %T %Z')"
        echo "=============================================================="
    } > "$report"

    generate_html_report "$state"
    log "Report generated: $report"
    log "HTML report generated: $state/patch_execution_report.html"
}

# ----------------------------- State selection ----------------------------

create_new_state() {
    RUN_ID="${DATE_TAG}_$$"
    ACTIVE_STATE="$STATE_BASE/$HOST/$RUN_ID"

    mkdir -p "$ACTIVE_STATE"
    mkdir -p "$BASE_DIR"

    set_value "$ACTIVE_STATE/status" "DOWNLOADING"
    set_value "$ACTIVE_STATE/run_id" "$RUN_ID"
    set_value "$ACTIVE_STATE/hostname" "$HOST"
    set_value "$ACTIVE_STATE/script_version" "$SCRIPT_VERSION"
    set_value "$ACTIVE_STATE/download_admin" "$(get_admin)"
    set_value "$ACTIVE_STATE/download_started" "$(date '+%F %T %Z')"
    set_value "$ACTIVE_STATE/os_id" "$OS_ID"
    set_value "$ACTIVE_STATE/os_version_id" "$OS_VERSION_ID"
    set_value "$ACTIVE_STATE/os_major" "$OS_MAJOR"
    set_value "$ACTIVE_STATE/arch" "$ARCH"

    local repo_dir="$BASE_DIR/updates-$RUN_ID"
    mkdir -p "$repo_dir"
    set_value "$ACTIVE_STATE/repo_dir" "$repo_dir"
}

# ----------------------------- DOWNLOAD -----------------------------------

download_updates() {
    local state repo_dir download_dir package_file admin_user admin_home rpm_count repo_hash

    CURRENT_PHASE="repository connectivity check"
    check_repository_connectivity ||
        die "Repository connectivity validation failed."

    echo
    read -r -p "Enter Linux username for the RPM inventory report: " admin_user

    [[ -n "$admin_user" ]] || die "Linux username cannot be empty."

    admin_home="$(getent passwd "$admin_user" | awk -F: '{print $6}')"
    [[ -n "$admin_home" && -d "$admin_home" ]] ||
        die "Linux user '$admin_user' does not exist or has no valid home directory."

    create_new_state
    state="$ACTIVE_STATE"
    repo_dir="$(get_value "$state/repo_dir")"

    set_value "$state/inventory_username" "$admin_user"
    set_value "$state/inventory_home" "$admin_home"
    set_value "$state/dns_test_name" "$DNS_TEST_NAME"

    CURRENT_PHASE="download prerequisites"
    log "Installing required download tools if missing..."

    if ! command -v createrepo_c >/dev/null 2>&1 ||
       ! rpm -q dnf-plugins-core >/dev/null 2>&1; then
        dnf install -y createrepo_c dnf-plugins-core
    fi

    check_repository_connectivity ||
        die "Repository connectivity validation failed after prerequisite installation."

    CURRENT_PHASE="download space preflight"
    check_download_space "$state" "$repo_dir"

    CURRENT_PHASE="download preparation"
    backup_dns "$state"

    log "Capturing RPM inventory..."
    capture_rpm_inventory "$state/rpm_inventory.txt"
    cp "$state/rpm_inventory.txt" "$admin_home/rpm_inventory_${RUN_ID}.txt"
    chown "$admin_user" "$admin_home/rpm_inventory_${RUN_ID}.txt"

    log "Downloading available package updates..."
    CURRENT_PHASE="package download"
    download_dir="$repo_dir/.dnf-download-cache"
    mkdir -p "$download_dir"
    dnf \
        --setopt=skip_if_unavailable=False \
        --setopt=retries="$DNF_RETRIES" \
        --setopt=timeout="$DNF_TIMEOUT" \
        upgrade --downloadonly --downloaddir="$download_dir" -y

    # DNF4 tracks --downloadonly packages as cache files and may remove them
    # after a later successful transaction. Move them out of its tracked path.
    while IFS= read -r -d '' package_file; do
        mv -- "$package_file" "$repo_dir/"
    done < <(find "$download_dir" -type f -name '*.rpm' -print0)
    rmdir "$download_dir" 2>/dev/null || true

    rpm_count="$(find "$repo_dir" -maxdepth 1 -type f -name '*.rpm' | wc -l | tr -d ' ')"

    if [[ "$rpm_count" -eq 0 ]]; then
        set_value "$state/status" "NO_UPDATES"
        set_value "$state/rpm_count" "0"
        set_value "$state/download_completed" "$(date '+%F %T %Z')"
        set_value "$state/repository_checksum_status" "NOT_APPLICABLE"
        ACTIVE_STATE=""
        generate_report "$state"
        log "No package updates were downloaded."
        log "Run report command to view the result."
        return 0
    fi

    log "Creating local repository metadata..."
    CURRENT_PHASE="repository metadata generation"
    createrepo_c "$repo_dir"

    (
        cd "$repo_dir"
        find . -type f ! -name SHA256SUMS -print0 |
            sort -z |
            xargs -0 -r sha256sum > SHA256SUMS
    )

    cat > "$repo_dir/REPOSITORY_INFO.txt" <<EOF
Run ID: $RUN_ID
Hostname: $HOST
OS ID: $OS_ID
OS version: $OS_VERSION_ID
Architecture: $ARCH
RPM count: $rpm_count
Created: $(date '+%F %T %Z')
EOF

    # Add REPOSITORY_INFO.txt to the checksum manifest.
    (
        cd "$repo_dir"
        find . -type f ! -name SHA256SUMS -print0 |
            sort -z |
            xargs -0 -r sha256sum > SHA256SUMS
        sha256sum --check SHA256SUMS
    )

    repo_hash="$(sha256sum "$repo_dir/SHA256SUMS" | awk '{print $1}')"
    set_value "$state/rpm_count" "$rpm_count"
    set_value "$state/repository_checksum_status" "PASSED"
    set_value "$state/repository_manifest_hash" "$repo_hash"
    set_value "$state/download_completed" "$(date '+%F %T %Z')"
    set_value "$state/status" "DOWNLOADED"

    ACTIVE_STATE="$state"
    generate_report "$state"

    log "Download completed successfully."
    log "Run ID: $RUN_ID"
    log "Repository: $repo_dir"
    log "RPM inventory: $admin_home/rpm_inventory_${RUN_ID}.txt"
}

# ----------------------------- INSTALL ------------------------------------

install_updates() {
    local state repo_dir status
    local kernel_before kernel_after default_kernel expected_kernel
    local boot_id_before transaction_id history_file
    local before_file after_file answer backup_dir

    CURRENT_PHASE="install selection"
    require_persistent_session install
    state="$(select_state "DOWNLOADED" "Select a downloaded patch run")"
    ACTIVE_STATE="$state"

    status="$(get_value "$state/status")"
    [[ "$status" == "DOWNLOADED" ]] || die "Selected run is not in DOWNLOADED status."

    repo_dir="$(get_value "$state/repo_dir")"
    [[ -d "$repo_dir" ]] || die "Local repository directory not found."

    # Validate OS identity, major release and architecture.
    [[ "$OS_ID" == "$(get_value "$state/os_id")" ]] ||
        die "OS ID mismatch. Downloaded on $(get_value "$state/os_id"), current OS is $OS_ID."

    [[ "$OS_MAJOR" == "$(get_value "$state/os_major")" ]] ||
        die "OS major version mismatch."

    [[ "$ARCH" == "$(get_value "$state/arch")" ]] ||
        die "Architecture mismatch."

    CURRENT_PHASE="repository validation"
    validate_repository "$state" "$repo_dir"
    set_value "$state/repository_checksum_status" "PASSED"

    log "Checking available updates in the local repository..."
    dnf \
        --disablerepo='*' \
        --repofrompath="${REPO_ID},file://${repo_dir}" \
        --enablerepo="$REPO_ID" \
        --setopt="${REPO_ID}.gpgcheck=0" \
        --setopt="${REPO_ID}.repo_gpgcheck=0" \
        repoquery --upgrades || true

    echo
    echo "The script is ready to install updates from:"
    echo "$repo_dir"
    echo
    read -r -p "Proceed with installation? (yes/no): " answer

    if [[ "$answer" != "yes" ]]; then
        set_value "$state/status" "CANCELLED"
        set_value "$state/cancelled_phase" "installation confirmation"
        set_value "$state/cancelled_at" "$(date '+%F %T %Z')"
        set_value "$state/cancellation_reason" "Administrator declined installation; no DNF install command was run."
        set_value "$state/install_completed" "NOT_STARTED"
        ACTIVE_STATE=""
        generate_report "$state"
        log "Installation cancelled. Run remains available for inspection; to retry, use report for details, then rerun download to create a fresh patch run."
        return 0
    fi

    CURRENT_PHASE="configuration backup"
    backup_configs "$state"
    backup_dir="$(get_value "$state/config_backup_dir")"
    echo
    echo "Configuration backup: $backup_dir"
    echo "This copy is on the server being patched. Copy it to separate secure storage before proceeding."
    read -r -p "Have you copied the backup elsewhere, or do you accept the risk of keeping only the local copy? (yes/no): " answer
    if [[ "$answer" != "yes" ]]; then
        set_value "$state/config_backup_copy_confirmed" "NO"
        ACTIVE_STATE=""
        generate_report "$state"
        log "Installation stopped before package changes. The run remains DOWNLOADED; copy the backup elsewhere and rerun install."
        return 0
    fi
    set_value "$state/config_backup_copy_confirmed" "YES"

    kernel_before="$(uname -r)"
    boot_id_before="$(cat /proc/sys/kernel/random/boot_id)"
    set_value "$state/install_admin" "$(get_admin)"
    set_value "$state/install_started" "$(date '+%F %T %Z')"
    set_value "$state/kernel_before_install" "$kernel_before"
    set_value "$state/boot_id_before_install" "$boot_id_before"
    before_file="$state/packages_before.txt"
    after_file="$state/packages_after.txt"
    CURRENT_PHASE="install preparation"
    capture_rpm_inventory "$before_file"

    CURRENT_PHASE="package installation"
    set_value "$state/status" "INSTALLING"
    log "Installing updates from the local repository only..."

    dnf \
        --disablerepo='*' \
        --repofrompath="${REPO_ID},file://${repo_dir}" \
        --enablerepo="$REPO_ID" \
        --setopt="${REPO_ID}.gpgcheck=0" \
        --setopt="${REPO_ID}.repo_gpgcheck=0" \
        --setopt=skip_if_unavailable=False \
        upgrade -y

    capture_rpm_inventory "$after_file"

    comm -13 "$before_file" "$after_file" > "$state/packages_added.txt"
    comm -23 "$before_file" "$after_file" > "$state/packages_removed.txt"

    {
        echo "Packages added or upgraded:"
        cat "$state/packages_added.txt"
        echo
        echo "Packages removed or replaced:"
        cat "$state/packages_removed.txt"
    } > "$state/package_changes.txt"

    # DNF history details and transaction ID.
    history_file="$state/dnf_history_info.txt"
    dnf history info last > "$history_file" 2>&1 || true

    transaction_id="$(
        awk -F: '
            tolower($1) ~ /transaction id/ {
                gsub(/[[:space:]]/, "", $2);
                print $2;
                exit
            }
        ' "$history_file"
    )"

    set_value "$state/dnf_transaction_id" "$transaction_id"

    kernel_after="$(uname -r)"
    set_value "$state/kernel_after_install" "$kernel_after"

    # The running kernel does not change until reboot.
    # Record the default boot kernel separately.
    default_kernel=""
    expected_kernel=""

    if command -v grubby >/dev/null 2>&1; then
        default_kernel="$(grubby --default-kernel 2>/dev/null || true)"
        if [[ -n "$default_kernel" ]]; then
            expected_kernel="$(basename "$default_kernel")"
            expected_kernel="${expected_kernel#vmlinuz-}"
        fi
    fi

    set_value "$state/default_kernel_after_install" "$default_kernel"
    set_value "$state/kernel_expected" "$expected_kernel"

    set_value "$state/install_completed" "$(date '+%F %T %Z')"

    if [[ ! -s "$state/package_changes.txt" ]] ||
       { [[ ! -s "$state/packages_added.txt" ]] && [[ ! -s "$state/packages_removed.txt" ]]; }; then
        set_value "$state/status" "NO_CHANGES"
        set_value "$state/reboot_required" "NO"
        log "No package changes detected. A reboot is not required by this patch run."
    else
        set_value "$state/status" "INSTALLED_PENDING_REBOOT"
        set_value "$state/reboot_required" "YES"
        set_value "$state/verification_status" "PENDING"
        log "Installation completed. Reboot is required before verification."
    fi

    ACTIVE_STATE=""
    generate_report "$state"

    echo
    log "Installation phase completed."
    log "Kernel running during installation: $kernel_after"
    log "Expected default boot kernel: ${expected_kernel:-NOT_DETERMINED}"
    echo
    echo "Next steps:"
    echo "  1. Schedule and perform a manual reboot during the maintenance window."
    echo "  2. After the server returns, run: sudo ./offline_patch.sh verify"
    echo "  3. Generate the report using: sudo ./offline_patch.sh report"
}

# ----------------------------- RECOVER -----------------------------------

recover_updates() {
    local state status failed_phase repo_dir answer
    local before_file after_file transaction_id history_file
    local kernel_after default_kernel expected_kernel
    local -a recoverable_states=()

    require_persistent_session recover

    while IFS= read -r state; do
        [[ -n "$state" ]] || continue
        status="$(get_value "$state/status")"
        failed_phase="$(get_value "$state/failed_phase")"
        if [[ "$status" == "INSTALLING" ||
              ( "$status" == "FAILED" &&
                ( "$failed_phase" == "package installation" ||
                  "$failed_phase" == "package installation recovery" ) ) ]]; then
            recoverable_states+=("$state")
        fi
    done < <(get_state_dirs "")

    ((${#recoverable_states[@]} > 0)) ||
        die "No interrupted or failed package installations are eligible for recovery. Use 'inspect' to review available runs."

    if ((${#recoverable_states[@]} == 1)); then
        state="${recoverable_states[0]}"
    else
        echo "Select an interrupted installation to recover:"
        local i choice
        for i in "${!recoverable_states[@]}"; do
            printf '%d) %-25s Status: %s  Phase: %s\n' \
                "$((i + 1))" "$(basename "${recoverable_states[$i]}")" \
                "$(get_value "${recoverable_states[$i]}/status")" \
                "$(get_value "${recoverable_states[$i]}/failed_phase")"
        done
        read -r -p "Enter selection: " choice
        [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid selection."
        ((choice >= 1 && choice <= ${#recoverable_states[@]})) || die "Selection out of range."
        state="${recoverable_states[$((choice - 1))]}"
    fi

    ACTIVE_STATE=""
    repo_dir="$(get_value "$state/repo_dir")"
    before_file="$state/packages_before.txt"
    after_file="$state/packages_after.txt"

    [[ -s "$before_file" ]] || die "Cannot recover: the pre-install package inventory is missing."
    [[ -d "$repo_dir" ]] || die "Cannot recover: local repository is missing: $repo_dir"
    [[ "$OS_ID" == "$(get_value "$state/os_id")" &&
       "$OS_MAJOR" == "$(get_value "$state/os_major")" &&
       "$ARCH" == "$(get_value "$state/arch")" ]] ||
        die "Cannot recover: current OS identity, major version, or architecture differs from the saved run."

    CURRENT_PHASE="recovery repository validation"
    validate_repository "$state" "$repo_dir"
    set_value "$state/repository_checksum_status" "PASSED"

    CURRENT_PHASE="recovery package database checks"
    rpm --verifydb || die "RPM database validation failed; recovery stopped."
    dnf --disablerepo='*' check || die "DNF found package consistency problems; recovery stopped. Review DNF output before proceeding."

    echo
    echo "Recovery will rerun the local-repository-only DNF upgrade."
    echo "DNF may complete remaining updates or report that the run is already complete."
    echo "Pre-install inventory: $before_file"
    echo "Current status: $(get_value "$state/status")"
    read -r -p "Proceed with recovery? (yes/no): " answer
    if [[ "$answer" != "yes" ]]; then
        ACTIVE_STATE=""
        log "Recovery cancelled. No DNF install command was run. The run remains unchanged."
        return 0
    fi

    CURRENT_PHASE="recovery configuration backup"
    backup_configs "$state"
    echo
    echo "Pre-recovery baseline: $(get_value "$state/recovery_linux_baseline_dir")"
    echo "Copy it to separate secure storage before proceeding."
    read -r -p "Have you copied the backup elsewhere, or do you accept the risk of keeping only the local copy? (yes/no): " answer
    if [[ "$answer" != "yes" ]]; then
        set_value "$state/config_backup_copy_confirmed" "NO"
        log "Recovery stopped before package changes. The interrupted run is unchanged."
        return 0
    fi
    set_value "$state/config_backup_copy_confirmed" "YES"

    set_value "$state/recovery_started" "$(date '+%F %T %Z')"
    set_value "$state/recovery_admin" "$(get_admin)"
    ACTIVE_STATE="$state"
    CURRENT_PHASE="package installation recovery"
    set_value "$state/status" "INSTALLING"
    dnf \
        --disablerepo='*' \
        --repofrompath="${REPO_ID},file://${repo_dir}" \
        --enablerepo="$REPO_ID" \
        --setopt="${REPO_ID}.gpgcheck=0" \
        --setopt="${REPO_ID}.repo_gpgcheck=0" \
        --setopt=skip_if_unavailable=False \
        upgrade -y

    capture_rpm_inventory "$after_file"
    comm -13 "$before_file" "$after_file" > "$state/packages_added.txt"
    comm -23 "$before_file" "$after_file" > "$state/packages_removed.txt"
    {
        echo "Packages added or upgraded:"
        cat "$state/packages_added.txt"
        echo
        echo "Packages removed or replaced:"
        cat "$state/packages_removed.txt"
    } > "$state/package_changes.txt"

    history_file="$state/dnf_history_info.txt"
    dnf history info last > "$history_file" 2>&1 || true
    transaction_id="$(awk -F: 'tolower($1) ~ /transaction id/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$history_file")"
    set_value "$state/dnf_transaction_id" "$transaction_id"

    kernel_after="$(uname -r)"
    set_value "$state/kernel_after_install" "$kernel_after"
    default_kernel=""
    expected_kernel=""
    if command -v grubby >/dev/null 2>&1; then
        default_kernel="$(grubby --default-kernel 2>/dev/null || true)"
        if [[ -n "$default_kernel" ]]; then
            expected_kernel="$(basename "$default_kernel")"
            expected_kernel="${expected_kernel#vmlinuz-}"
        fi
    fi
    set_value "$state/default_kernel_after_install" "$default_kernel"
    set_value "$state/kernel_expected" "$expected_kernel"
    set_value "$state/install_completed" "$(date '+%F %T %Z')"
    set_value "$state/recovery_completed" "$(date '+%F %T %Z')"

    if [[ ! -s "$state/packages_added.txt" && ! -s "$state/packages_removed.txt" ]]; then
        set_value "$state/status" "NO_CHANGES"
        set_value "$state/reboot_required" "NO"
        set_value "$state/recovery_result" "NO_PACKAGE_CHANGES"
    else
        set_value "$state/status" "INSTALLED_PENDING_REBOOT"
        set_value "$state/reboot_required" "YES"
        set_value "$state/verification_status" "PENDING"
        set_value "$state/recovery_result" "INSTALLATION_RECONCILED"
    fi

    : > "$state/error"
    : > "$state/failed_phase"
    : > "$state/failed_at"
    ACTIVE_STATE=""
    generate_report "$state"
    log "Recovery completed. Final status: $(get_value "$state/status")."
}

# ----------------------------- VERIFY -------------------------------------

verify_updates() {
    local state current_boot_id previous_boot_id
    local current_os_id current_os_major
    local default_kernel running_kernel expected_kernel
    local transaction_id history_output
    local nameservers search_domain dns_test_name
    local failures=0
    local failure_file details_file
    local verification_admin

    CURRENT_PHASE="verification selection"
    state="$(select_state "INSTALLED_PENDING_REBOOT" "Select an installed patch run to verify")"

    ACTIVE_STATE="$state"
    verification_admin="$(get_admin)"
    failure_file="$state/verification_failures.txt"
    details_file="$state/verification_details.txt"

    : > "$failure_file"
    : > "$details_file"

    set_value "$state/verification_admin" "$verification_admin"
    set_value "$state/verification_attempt_time" "$(date '+%F %T %Z')"
    set_value "$state/verification_status" "RUNNING"
    set_value "$state/status" "VERIFYING"
    CURRENT_PHASE="post-reboot verification"

    log "Starting automatic post-reboot verification..."

    local baseline_dir
    baseline_dir="$(get_value "$state/config_backup_dir")"
    if [[ -n "$baseline_dir" && -d "$baseline_dir/before" ]]; then
        collect_linux_snapshot "$baseline_dir" post
        diff -ru "$baseline_dir/before" "$baseline_dir/post" \
            > "$state/linux_baseline_diff.txt" || true
        set_value "$state/linux_baseline_diff" "$state/linux_baseline_diff.txt"
        echo "INFO: Linux post-reboot snapshot captured; differences are recorded in $state/linux_baseline_diff.txt" |
            tee -a "$details_file"
    else
        echo "INFO: No Linux pre-patch baseline is available for comparison." |
            tee -a "$details_file"
    fi

    # 1. Reboot detection using boot ID.
    previous_boot_id="$(get_value "$state/boot_id_before_install")"
    current_boot_id="$(cat /proc/sys/kernel/random/boot_id)"

    set_value "$state/boot_id_after_reboot" "$current_boot_id"

    if [[ -n "$previous_boot_id" && "$current_boot_id" != "$previous_boot_id" ]]; then
        set_value "$state/reboot_status" "PASSED"
        echo "PASS: A reboot has been detected." | tee -a "$details_file"
    else
        set_value "$state/reboot_status" "FAILED"
        echo "FAIL: No reboot detected since installation." | tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    # 2. OS identity and major version.
    # Minor version upgrades are allowed; major version must remain the same.
    # shellcheck disable=SC1091
    source /etc/os-release
    current_os_id="${ID:-unknown}"
    current_os_major="${VERSION_ID%%.*}"

    if [[ "$current_os_id" == "$(get_value "$state/os_id")" &&
          "$current_os_major" == "$(get_value "$state/os_major")" ]]; then
        set_value "$state/os_validation" "PASSED"
        echo "PASS: OS identity and major version match." | tee -a "$details_file"
    else
        set_value "$state/os_validation" "FAILED"
        echo "FAIL: OS identity or major version mismatch." | tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    # 3. Kernel verification.
    running_kernel="$(uname -r)"
    expected_kernel="$(get_value "$state/kernel_expected")"
    default_kernel=""

    if command -v grubby >/dev/null 2>&1; then
        default_kernel="$(grubby --default-kernel 2>/dev/null || true)"
    fi

    set_value "$state/kernel_after_reboot" "$running_kernel"
    set_value "$state/default_kernel_after_reboot" "$default_kernel"

    if [[ -n "$expected_kernel" &&
          "$running_kernel" == "$expected_kernel" &&
          -n "$default_kernel" &&
          -f "$default_kernel" ]]; then
        set_value "$state/kernel_validation" "PASSED"
        echo "PASS: Running kernel matches the expected default boot kernel ($running_kernel)." |
            tee -a "$details_file"
    else
        set_value "$state/kernel_validation" "FAILED"
        {
            echo "FAIL: Kernel validation failed."
            echo "Expected kernel : ${expected_kernel:-NOT_RECORDED}"
            echo "Running kernel  : $running_kernel"
            echo "Default kernel  : ${default_kernel:-NOT_AVAILABLE}"
        } | tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    # 4. DNS restoration and DNS resolution.
    dns_test_name="$(get_value "$state/dns_test_name")"
    [[ -n "$dns_test_name" ]] || dns_test_name="$DNS_TEST_NAME"

    set_value "$state/dns_test_name" "$dns_test_name"

    if restore_dns "$state"; then
        echo "PASS: DNS backup restored and content matches." | tee -a "$details_file"
    else
        set_value "$state/dns_restored" "FAILED"
        echo "FAIL: DNS restoration failed." | tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    nameservers="$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ',' - || true)"
    search_domain="$(awk '
        $1 == "search" { for (i=2; i<=NF; i++) printf "%s%s", (i==2 ? "" : " "), $i }
        $1 == "domain" { if ($2 != "") printf "%s%s", (length($0)>0 ? " " : ""), $2 }
    ' /etc/resolv.conf 2>/dev/null | sed 's/^ *//;s/ *$//' || true)"

    set_value "$state/dns_nameserver" "$nameservers"
    set_value "$state/dns_search" "$search_domain"

    if [[ -n "$nameservers" ]]; then
        echo "PASS: At least one nameserver is configured: $nameservers" | tee -a "$details_file"
    else
        echo "FAIL: No nameserver entry found in /etc/resolv.conf." |
            tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    # A search domain is optional and is not a verification failure.
    if [[ -n "$search_domain" ]]; then
        echo "INFO: DNS search domain: $search_domain" | tee -a "$details_file"
    else
        echo "INFO: No DNS search domain configured; this is not treated as a failure." |
            tee -a "$details_file"
    fi

    if [[ -n "$dns_test_name" ]] &&
       timeout 10 getent ahosts "$dns_test_name" >/dev/null 2>&1; then
        set_value "$state/dns_resolution_status" "PASSED"
        echo "PASS: Name resolution succeeded for $dns_test_name." | tee -a "$details_file"
    else
        set_value "$state/dns_resolution_status" "FAILED"
        echo "FAIL: Name resolution failed for $dns_test_name." |
            tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    # 5. DNF transaction validation.
    transaction_id="$(get_value "$state/dnf_transaction_id")"

    if [[ -n "$transaction_id" ]] &&
       dnf history info "$transaction_id" > "$state/dnf_history_verify.txt" 2>&1 &&
       grep -Eq "Transaction ID[[:space:]]*:[[:space:]]*${transaction_id}" "$state/dnf_history_verify.txt"; then
        set_value "$state/dnf_transaction_validation" "PASSED"
        echo "PASS: DNF transaction $transaction_id is present in history." |
            tee -a "$details_file"
    else
        set_value "$state/dnf_transaction_validation" "FAILED"
        echo "FAIL: DNF transaction could not be validated (ID: ${transaction_id:-NOT_RECORDED})." |
            tee -a "$failure_file" "$details_file"
        ((failures+=1))
    fi

    # 6. Record final verification result.
    set_value "$state/verification_failure_count" "$failures"

    if ((failures == 0)); then
        set_value "$state/verification_status" "PASSED"
        set_value "$state/status" "VERIFIED"
        set_value "$state/verification_completed" "$(date '+%F %T %Z')"
        log "ALL AUTOMATIC VERIFICATION CHECKS PASSED."
        log "Patch run is now marked VERIFIED."
    else
        # Keep lifecycle status pending so the administrator can correct
        # the issue and rerun verification. Do not mark the run VERIFIED.
        set_value "$state/verification_status" "FAILED"
        set_value "$state/status" "INSTALLED_PENDING_REBOOT"
        set_value "$state/verification_completed" "NOT_COMPLETED"
        log "$failures verification check(s) failed."
        log "Patch run remains INSTALLED_PENDING_REBOOT and can be verified again."
    fi

    ACTIVE_STATE=""
    generate_report "$state"

    echo
    echo "Verification details: $details_file"
    echo "Verification failures: $failure_file"
    echo "Execution report: $state/patch_execution_report.txt"
}

# ----------------------------- REPORT -------------------------------------

report_updates() {
    local state

    state="$(select_state "" "Select a patch run for the report")"
    generate_report "$state"

    echo
    cat "$state/patch_execution_report.txt"
}

# ----------------------------- INSPECT -----------------------------------

inspect_updates() {
    local state
    local -a available_states=()

    while IFS= read -r state; do
        [[ -n "$state" ]] && available_states+=("$state")
    done < <(get_state_dirs "")

    if ((${#available_states[@]} == 0)); then
        log "No patch runs found for host '$HOST' in $STATE_BASE/$HOST. Run 'download' to create a patch run."
        return 0
    fi

    state="$(select_state "" "Select a patch run to inspect")"
    echo "Run directory : $state"
    echo "Status        : $(get_value "$state/status")"
    echo "Failed phase  : $(get_value "$state/failed_phase")"
    echo "Failure time  : $(get_value "$state/failed_at")"
    echo "Error         : $(get_value "$state/error")"
    echo "Cancellation  : $(get_value "$state/cancellation_reason")"
    echo "Repo path     : $(get_value "$state/repo_dir")"
    echo "Report        : $state/patch_execution_report.txt"
    case "$(get_value "$state/status")" in
        FAILED)
            if [[ "$(get_value "$state/failed_phase")" == "package installation" ||
                  "$(get_value "$state/failed_phase")" == "package installation recovery" ||
                  "$(get_value "$state/status")" == "INSTALLING" ]]; then
                echo "Recovery      : After reviewing the recorded error, run 'sudo $0 recover' to validate package state and the saved repository before a confirmed local retry."
            else
                echo "Recovery      : Review the error and report. Correct the cause; for a failed download, start a fresh download. This run is not eligible for install recovery."
            fi
            ;;
        INSTALLING)
            echo "Recovery      : This run appears interrupted. Run 'sudo $0 recover' to validate package state and the saved repository before a confirmed local retry."
            ;;
        CANCELLED)
            echo "Recovery      : No installation was started. Start a fresh download to create a new installable run."
            ;;
    esac
}

# ----------------------------- MAIN ---------------------------------------

show_usage() {
    cat <<EOF
Offline Patch Management Script v$SCRIPT_VERSION

Usage:
  sudo $0 download
  sudo $0 install
  sudo reboot
  sudo $0 verify
  sudo $0 report
  sudo $0 inspect
  sudo $0 recover

Commands:
  download  Validate enabled repositories and download updates locally.
  install   Install updates from the local repository only.
  verify    Automatically verify the post-reboot state.
  report    Generate and display the patch execution report.
  inspect   Inspect a run's status, failure phase, and recovery guidance.
  recover   Validate and retry an interrupted local package installation.

Supported:
  Rocky Linux / RHEL / AlmaLinux / Oracle Linux 8 and 9 (DNF4)
  Rocky Linux 10 (gated; DNF4 and x86-64-v3 checks required)
EOF
}

main() {
    case "${1:-}" in
        -h|--help|help)
            show_usage
            return 0
            ;;
    esac

    require_root
    check_commands
    get_os_info
    validate_rocky10_environment
    acquire_lock

    CURRENT_COMMAND="${1:-}"

    trap 'handle_error $? $LINENO' ERR
    trap cleanup EXIT

    case "$CURRENT_COMMAND" in
        download)
            download_updates
            ;;
        install)
            install_updates
            ;;
        verify)
            verify_updates
            ;;
        report)
            report_updates
            ;;
        inspect)
            inspect_updates
            ;;
        recover)
            recover_updates
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
