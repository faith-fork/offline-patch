#!/usr/bin/env bash
# Linux configuration and operational baseline capture.
# This is not a full-system backup and does not provide rollback.

linux_backup_root() {
    printf '%s/%s/linux-backups\n' "$STATE_BASE" "$HOST"
}

linux_backup_capture() {
    local phase="$1" backup_id="$2" target="$3"
    local capture="$target/$phase"
    mkdir -p "$capture"
    chmod 700 "$target" "$capture"

    {
        date '+%F %T %Z'
        hostnamectl 2>&1 || true
        cat /etc/os-release 2>/dev/null || true
        uname -a
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort
    } > "$capture/system-inventory.txt"

    {
        ip -brief address 2>&1 || true
        ip route show table all 2>&1 || true
        ip -6 route show table all 2>&1 || true
        nmcli connection show 2>&1 || true
        findmnt --real 2>&1 || true
        lsblk -f 2>&1 || true
        df -hT 2>&1 || true
    } > "$capture/network-storage.txt"

    {
        systemctl list-unit-files --type=service --no-pager 2>&1 || true
        systemctl --failed --no-legend --no-pager 2>&1 || true
        systemctl list-timers --all --no-pager 2>&1 || true
        firewall-cmd --list-all-zones 2>&1 || true
        firewall-cmd --direct --get-all-rules 2>&1 || true
        getent passwd 2>&1 || true
        getent group 2>&1 || true
        crontab -l -u root 2>&1 || true
    } > "$capture/services-security.txt"

    local -a paths=(
        etc/hostname etc/hosts etc/fstab etc/crypttab etc/resolv.conf
        etc/nsswitch.conf etc/ssh/sshd_config etc/ssh/sshd_config.d
        etc/sudoers etc/sudoers.d etc/sysctl.conf etc/sysctl.d
        etc/security/limits.conf etc/security/limits.d
        etc/systemd/system etc/NetworkManager/system-connections
        etc/NetworkManager/conf.d etc/firewalld
    )
    local existing=()
    local p archive_listing
    for p in "${paths[@]}"; do
        [[ -e "/$p" ]] && existing+=("$p")
    done

    if ((${#existing[@]} == 0)); then
        echo "No configured system paths were found; refusing to create an empty configuration archive." > "$capture/tar-errors.txt"
        log "ERROR: No configuration paths were found for the Linux backup."
        return 1
    fi

    # Archive from / so paths resolve regardless of the caller working directory.
    if ! tar --create --gzip --file "$capture/etc-config.tar.gz" \
        --directory / --numeric-owner --acls --xattrs \
        --warning=no-file-changed "${existing[@]}" 2>"$capture/tar-errors.txt"; then
        log "ERROR: Configuration archive creation failed; inspect $capture/tar-errors.txt"
        return 1
    fi

    # Validate archive readability and ensure it contains at least one entry.
    archive_listing="$capture/.etc-config-archive-list"
    if ! tar --list --gzip --file "$capture/etc-config.tar.gz" > "$archive_listing" 2>>"$capture/tar-errors.txt" ||
       [[ ! -s "$archive_listing" ]]; then
        echo "Configuration archive validation failed or archive contains no entries." >> "$capture/tar-errors.txt"
        rm -f "$archive_listing"
        log "ERROR: Configuration archive validation failed; inspect $capture/tar-errors.txt"
        return 1
    fi
    rm -f "$archive_listing"
    (
        cd "$capture" || exit 1
        find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS
    )
    printf '%s\n' "$backup_id" > "$capture/backup_id"
    printf '%s\n' "$phase" > "$capture/phase"
    printf '%s\n' "$(date '+%F %T %Z')" > "$capture/captured_at"
    return 0
}

linux_backup() {
    local profile="${1:-}" phase="" root target backup_id pre_dir post_dir
    shift || true
    [[ "$profile" == "linux" ]] || die "Usage: $0 backup linux --phase pre|post"
    while (($#)); do
        case "$1" in
            --phase) (($# >= 2)) || die "--phase requires pre or post"; phase="$2"; shift 2 ;;
            *) die "Unknown backup option: $1" ;;
        esac
    done
    [[ "$phase" == "pre" || "$phase" == "post" ]] || die "Backup phase must be pre or post."
    root="$(linux_backup_root)"
    mkdir -p "$root"
    chmod 700 "$root"

    if [[ "$phase" == "pre" ]]; then
        [[ ! -s "$root/latest_pre" ]] || die "An unmatched pre-backup already exists. Complete its post phase first."
        backup_id="$(date +%Y%m%d_%H%M%S_%N)"
        target="$root/$backup_id"
        mkdir -p "$target"
        printf '%s\n' "$backup_id" > "$target/backup_id"
        printf '%s\n' "$HOST" > "$target/hostname"
        printf '%s\n' "$(date '+%F %T %Z')" > "$target/created_at"
        if ! linux_backup_capture pre "$backup_id" "$target"; then
            echo FAILED > "$target/pre/capture_status"
            echo "Linux pre-backup capture failed; see tar-errors.txt and run.log." > "$target/pre/capture_error"
            die "Linux pre-backup failed. Incomplete capture retained at $target/pre; latest_pre was not updated."
        fi
        echo PASSED > "$target/pre/capture_status"
        printf '%s\n' "$backup_id" > "$root/latest_pre"
        log "Linux pre-patch baseline captured: $target/pre"
        return 0
    fi

    backup_id="$(cat "$root/latest_pre" 2>/dev/null || true)"
    [[ -n "$backup_id" ]] || die "No unmatched Linux pre-backup found. Run backup linux --phase pre first."
    target="$root/$backup_id"
    [[ -d "$target/pre" && ! -d "$target/post" ]] || die "Latest pre-backup is missing or already has a post capture."
    if ! linux_backup_capture post "$backup_id" "$target"; then
        echo FAILED > "$target/post/capture_status"
        echo "Linux post-backup capture failed; see tar-errors.txt and run.log." > "$target/post/capture_error"
        die "Linux post-backup failed. Incomplete capture retained at $target/post; latest_pre remains unchanged."
    fi
    echo PASSED > "$target/post/capture_status"
    ( cd "$target/pre" || exit 1; sha256sum --check SHA256SUMS >/dev/null ) || die "Pre-backup checksum validation failed."
    ( cd "$target/post" || exit 1; sha256sum --check SHA256SUMS >/dev/null ) || die "Post-backup checksum validation failed."
    pre_dir="$target/pre"
    post_dir="$target/post"
    diff -u "$pre_dir/system-inventory.txt" "$post_dir/system-inventory.txt" > "$target/system-inventory.diff" || true
    diff -u "$pre_dir/network-storage.txt" "$post_dir/network-storage.txt" > "$target/network-storage.diff" || true
    diff -u "$pre_dir/services-security.txt" "$post_dir/services-security.txt" > "$target/services-security.diff" || true
    {
        echo "LINUX BACKUP COMPARISON"
        echo "Host: $HOST"
        echo "Backup ID: $backup_id"
        echo "Pre capture: $(cat "$pre_dir/captured_at")"
        echo "Post capture: $(cat "$post_dir/captured_at")"
        echo
        for f in system-inventory network-storage services-security; do
            echo "===== $f differences ====="
            if [[ -s "$target/$f.diff" ]]; then cat "$target/$f.diff"; else echo "No differences."; fi
            echo
        done
        echo "Configuration archives: pre/etc-config.tar.gz and post/etc-config.tar.gz"
        echo "Compare archive contents/checksums separately; archives are not auto-restored."
    } > "$target/comparison-report.txt"
    printf '%s\n' "$backup_id" > "$root/latest_completed"
    rm -f "$root/latest_pre"
    log "Linux post-patch baseline and comparison report created: $target/comparison-report.txt"
}
