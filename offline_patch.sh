#!/usr/bin/env bash
#
# offline_patch.sh
#
# Individual-server offline patch management for Rocky Linux / RHEL 8 and 9.
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
DNS_TEST_NAME="${DNS_TEST_NAME:-rockylinux.org}"

CONNECTIVITY_ATTEMPTS=3
CONNECTIVITY_RETRY_DELAY=10
DNF_TIMEOUT=30
DNF_RETRIES=2

# -------------------------------------------------------------------------

SCRIPT_VERSION="1.0.0"
HOST="$(hostname -s)"
DATE_TAG="$(date +%Y%m%d_%H%M%S)"
RUN_ID=""
ACTIVE_STATE=""
CURRENT_COMMAND=""
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

check_commands() {
    local cmd
    for cmd in dnf rpm sha256sum awk sed grep sort comm hostname stat \
               getent timeout flock date find basename readlink cp chmod \
               chown cat wc tr sleep xargs paste cmp id tee mkdir; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command not found: $cmd"
    done
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

    [[ "$OS_MAJOR" == "8" || "$OS_MAJOR" == "9" ]] ||
        die "Unsupported OS major version: $OS_MAJOR. This script targets version 8 or 9."
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

        if [[ "$status" == "DOWNLOADING" || "$status" == "INSTALLING" ]]; then
            set_value "$ACTIVE_STATE/status" "FAILED"
            set_value "$ACTIVE_STATE/error" "Command failed at line $line with exit code $rc"
        elif [[ "$status" == "INSTALLED_PENDING_REBOOT" &&
                "$(get_value "$ACTIVE_STATE/verification_status")" == "RUNNING" ]]; then
            set_value "$ACTIVE_STATE/verification_status" "FAILED"
            set_value "$ACTIVE_STATE/verification_completed" "INTERRUPTED"
            set_value "$ACTIVE_STATE/verification_error" "Verification interrupted at line $line with exit code $rc"
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

    # Compare only; never overwrite resolver-managed configuration.
    if cmp -s "$backup" /etc/resolv.conf; then
        set_value "$state/dns_restored" "UNCHANGED"
        log "DNS configuration matches the saved baseline; no changes made."
        return 0
    fi
    set_value "$state/dns_restored" "CHANGED"
    log "DNS configuration differs from the saved baseline; left untouched."
    return 1
}

# ----------------------------- Repository integrity -----------------------

validate_repository() {
    local state="$1"
    local repo_dir="$2"

    [[ -d "$repo_dir" ]] || die "Local repository directory is missing: $repo_dir"
    [[ -s "$repo_dir/SHA256SUMS" ]] || die "SHA256SUMS manifest is missing."

    local expected_hash actual_hash current_list expected_list
    expected_list="$state/repository_file_list.txt"
    current_list="$state/repository_file_list.current"
    expected_hash="$(get_value "$state/repository_manifest_hash")"
    [[ -n "$expected_hash" ]] || die "Stored repository manifest hash is missing."
    actual_hash="$(sha256sum "$repo_dir/SHA256SUMS" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || die "Repository manifest hash mismatch."
    (
        cd "$repo_dir"
        sha256sum --check SHA256SUMS
        find . -type f ! -name SHA256SUMS -printf '%P\n' | sort
    ) > "$current_list" || die "Repository checksum validation failed."
    [[ -s "$expected_list" ]] || die "Stored repository file inventory is missing."
    if ! cmp -s "$expected_list" "$current_list"; then
        diff -u "$expected_list" "$current_list" || true
        die "Repository file inventory changed."
    fi
    rm -f "$current_list"
    log "Repository manifest, file inventory and checksums passed."
}

# ----------------------------- RPM inventory ------------------------------

capture_rpm_inventory() {
    local output_file="$1"

    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' |
        sort > "$output_file"
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
        echo
        echo "---------------------- Installation -------------------------"
        echo "Install started         : $(get_value "$state/install_started")"
        echo "Install completed       : $(get_value "$state/install_completed")"
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
        echo "DNS comparison          : $(get_value "$state/dns_restored")"
        echo "DNS nameserver          : $(get_value "$state/dns_nameserver")"
        echo "DNS search domain       : $(get_value "$state/dns_search")"
        echo "DNS resolution test     : $(get_value "$state/dns_resolution_status")"
        echo "DNS test hostname       : $(get_value "$state/dns_test_name")"
        echo
        echo "Verification failures:"
        local latest_failures
        latest_failures="$(get_value "$state/latest_verification_failures")"
        if [[ -n "$latest_failures" && -s "$latest_failures" ]]; then
            cat "$latest_failures"
        else
            echo "None recorded in the latest attempt."
        fi
        echo
        echo "---------------------- Supporting Files ---------------------"
        echo "RPM inventory           : $state/rpm_inventory.txt"
        echo "Package changes         : $state/package_changes.txt"
        echo "DNF transaction details : $state/dnf_history_info.txt"
        echo "Verification details    : $(get_value "$state/latest_verification_details")"
        echo
        echo "=============================================================="
        echo "Generated: $(date '+%F %T %Z')"
        echo "=============================================================="
    } > "$report"

    log "Report generated: $report"
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
    local state repo_dir admin_user admin_home rpm_count

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

    log "Installing required download tools if missing..."

    if ! command -v createrepo_c >/dev/null 2>&1 ||
       ! rpm -q dnf-plugins-core >/dev/null 2>&1; then
        dnf install -y createrepo_c dnf-plugins-core
    fi

    check_repository_connectivity ||
        die "Repository connectivity validation failed after prerequisite installation."

    backup_dns "$state"

    log "Capturing RPM inventory..."
    capture_rpm_inventory "$state/rpm_inventory.txt"
    cp "$state/rpm_inventory.txt" "$admin_home/rpm_inventory_${RUN_ID}.txt"
    chown "$admin_user" "$admin_home/rpm_inventory_${RUN_ID}.txt"

    log "Downloading available package updates..."
    dnf \
        --setopt=skip_if_unavailable=False \
        --setopt=retries="$DNF_RETRIES" \
        --setopt=timeout="$DNF_TIMEOUT" \
        upgrade --downloadonly --downloaddir="$repo_dir" -y

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
    createrepo_c "$repo_dir"

    (
        cd "$repo_dir"
        find . -type f ! -name SHA256SUMS -print0 |
            sort -z |
            xargs -0 -r sha256sum > SHA256SUMS
    )

    local repo_hash
    repo_hash="$(sha256sum "$repo_dir/SHA256SUMS" | awk '{print $1}')"

    set_value "$state/rpm_count" "$rpm_count"
    set_value "$state/repository_checksum_status" "CREATED"
    set_value "$state/repository_manifest_hash" "$repo_hash"
    set_value "$state/download_completed" "$(date '+%F %T %Z')"
    set_value "$state/status" "DOWNLOADED"

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
    )

    set_value "$state/repository_manifest_hash" \
        "$(sha256sum "$repo_dir/SHA256SUMS" | awk '{print $1}')"
    (
        cd "$repo_dir"
        find . -type f ! -name SHA256SUMS -printf '%P\n' | sort
    ) > "$state/repository_file_list.txt"

    ACTIVE_STATE=""
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
    local before_file after_file preview_file preview_rc

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

    validate_repository "$state" "$repo_dir"
    set_value "$state/repository_checksum_status" "PASSED"

    kernel_before="$(uname -r)"
    boot_id_before="$(cat /proc/sys/kernel/random/boot_id)"

    set_value "$state/install_admin" "$(get_admin)"
    set_value "$state/install_started" "$(date '+%F %T %Z')"
    set_value "$state/kernel_before_install" "$kernel_before"
    set_value "$state/boot_id_before_install" "$boot_id_before"
    set_value "$state/status" "INSTALLING"

    before_file="$state/packages_before.txt"
    after_file="$state/packages_after.txt"
    systemctl --failed --no-legend --no-pager > "$state/failed_services_before.txt" 2>&1 || true
    capture_rpm_inventory "$before_file"

    log "Previewing the DNF transaction from the local repository..."
    preview_file="$state/dnf_transaction_preview.txt"
    set +e
    dnf \
        --disablerepo='*' \
        --repofrompath="${REPO_ID},file://${repo_dir}" \
        --enablerepo="$REPO_ID" \
        --setopt="${REPO_ID}.gpgcheck=0" \
        --setopt="${REPO_ID}.repo_gpgcheck=0" \
        --setopt=skip_if_unavailable=False \
        upgrade --assumeno > "$preview_file" 2>&1
    preview_rc=$?
    set -e
    cat "$preview_file"
    if ((preview_rc != 0)) && ! grep -Eqi 'Operation aborted|Transaction.*aborted|Nothing to do' "$preview_file"; then
        die "DNF transaction preview failed (exit code $preview_rc)."
    fi
    echo
    echo "Review the DNF transaction summary above. Preview: $preview_file"
    read -r -p "Proceed with this package transaction? Type 'yes': " answer
    [[ "$answer" == "yes" ]] || die "Installation cancelled by administrator."

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
    systemctl --failed --no-legend --no-pager > "$state/failed_services_after.txt" 2>&1 || true
    comm -13 "$state/failed_services_before.txt" "$state/failed_services_after.txt" > "$state/failed_services_new.txt" || true
    comm -23 "$state/failed_services_before.txt" "$state/failed_services_after.txt" > "$state/failed_services_recovered.txt" || true
    if command -v needs-restarting >/dev/null 2>&1; then
        set +e
        needs-restarting -r > "$state/needs_restarting.txt" 2>&1
        echo "$?" > "$state/needs_restarting_rc"
        set -e
    else
        set_value "$state/needs_restarting_rc" "NOT_INSTALLED"
    fi
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

    state="$(select_state "INSTALLED_PENDING_REBOOT" "Select an installed patch run to verify")"

    ACTIVE_STATE="$state"
    verification_admin="$(get_admin)"
    local attempt_stamp
    attempt_stamp="$(date '+%Y%m%d_%H%M%S')"
    failure_file="$state/verification_failures_${attempt_stamp}.txt"
    details_file="$state/verification_details_${attempt_stamp}.txt"
    set_value "$state/latest_verification_failures" "$failure_file"
    set_value "$state/latest_verification_details" "$details_file"
    set_value "$state/verification_admin" "$verification_admin"
    set_value "$state/verification_attempt_time" "$(date '+%F %T %Z')"
    set_value "$state/verification_status" "RUNNING"

    log "Starting automatic post-reboot verification..."

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

# ----------------------------- MAIN ---------------------------------------

main() {
    require_root
    check_commands
    get_os_info
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
        *)
            cat <<EOF
Offline Patch Management Script v$SCRIPT_VERSION

Usage:
  sudo $0 download
  sudo $0 install
  sudo reboot
  sudo $0 verify
  sudo $0 report

Commands:
  download  Validate enabled repositories and download updates locally.
  install   Install updates from the local repository only.
  verify    Automatically verify the post-reboot state.
  report    Generate and display the patch execution report.

Supported:
  Rocky Linux / RHEL 8 and 9 (DNF4)

EOF
            exit 1
            ;;
    esac
}

main "$@"
