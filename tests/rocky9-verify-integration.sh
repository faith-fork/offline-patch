#!/usr/bin/env bash
# Disposable Rocky Linux 9 post-reboot verification lifecycle integration test.
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
SOURCE_SCRIPT="$ROOT/offline_patch.sh"
WORK="$(mktemp -d /tmp/offline-patch-verify.XXXXXX)"
HOST="$(hostname -s)"
STATE_BASE="$WORK/state"
STATE="$STATE_BASE/$HOST/verify-fixture"
BASE_DIR="$WORK/base"
LOCK_FILE="$WORK/lock"
BIN="$WORK/bin"
SCRIPT="$WORK/offline_patch-test.sh"
BOOT_ID_FILE="$WORK/boot_id"
KERNEL_FILE="/boot/vmlinuz-offline-patch-test"
RESOLV_BEFORE="$(sha256sum /etc/resolv.conf | awk '{print $1}')"

cleanup() {
  rm -f "$KERNEL_FILE"
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "Run this integration test as root."; exit 1; }
source /etc/os-release
[[ "$ID" == rocky && "${VERSION_ID%%.*}" == 9 ]] || { echo "This test requires Rocky Linux 9."; exit 1; }

mkdir -p "$BIN" "$STATE" "$BASE_DIR" /boot
cp "$SOURCE_SCRIPT" "$SCRIPT"
sed -i \
  -e "s|^BASE_DIR=.*|BASE_DIR=\"$BASE_DIR\"|" \
  -e "s|^STATE_BASE=.*|STATE_BASE=\"$STATE_BASE\"|" \
  -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$LOCK_FILE\"|" \
  -e "s|cat /proc/sys/kernel/random/boot_id|cat \"$BOOT_ID_FILE\"|" \
  "$SCRIPT"

cat > "$BIN/grubby" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--default-kernel" ]] && printf '%s\n' "$TEST_KERNEL_FILE"
EOF
cat > "$BIN/dnf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "history" && "${2:-}" == "info" && "${3:-}" == "77" ]]; then
  printf 'Transaction ID : 77\n'
  exit 0
fi
echo "Unexpected DNF invocation: $*" >&2
exit 2
EOF
chmod +x "$BIN/grubby" "$BIN/dnf"
touch "$KERNEL_FILE"

running_kernel="$(uname -r)"
printf '%s\n' "$running_kernel" > "$WORK/kernel_expected"
printf 'boot-before-test\n' > "$BOOT_ID_FILE"

cat > "$STATE/status" <<'EOF'
INSTALLED_PENDING_REBOOT
EOF
printf 'verify-fixture\n' > "$STATE/run_id"
printf '%s\n' "$ID" > "$STATE/os_id"
printf '%s\n' "${VERSION_ID%%.*}" > "$STATE/os_major"
printf 'boot-before-test\n' > "$STATE/boot_id_before_install"
printf '%s\n' "$running_kernel" > "$STATE/kernel_expected"
printf '77\n' > "$STATE/dnf_transaction_id"
printf 'localhost\n' > "$STATE/dns_test_name"
cp /etc/resolv.conf "$STATE/resolv.conf.backup"
stat -c '%a' /etc/resolv.conf > "$STATE/dns_original_mode"
stat -c '%u' /etc/resolv.conf > "$STATE/dns_original_uid"
stat -c '%g' /etc/resolv.conf > "$STATE/dns_original_gid"

# First attempt: no reboot occurred. It must fail safely and remain retryable.
TEST_KERNEL_FILE="$KERNEL_FILE" PATH="$BIN:$PATH" bash "$SCRIPT" verify
[[ "$(cat "$STATE/status")" == "INSTALLED_PENDING_REBOOT" ]]
[[ "$(cat "$STATE/verification_status")" == "FAILED" ]]
[[ "$(cat "$STATE/reboot_status")" == "FAILED" ]]
[[ "$(cat "$STATE/kernel_validation")" == "PASSED" ]]
echo "PASS: verification detects missing reboot and preserves retryable lifecycle state."

# Second attempt: simulate a new boot ID; all other checks remain controlled.
sleep 1
printf 'boot-after-test\n' > "$BOOT_ID_FILE"
PATH="$BIN:$PATH" bash "$SCRIPT" verify
[[ "$(cat "$STATE/status")" == "VERIFIED" ]]
[[ "$(cat "$STATE/verification_status")" == "PASSED" ]]
[[ "$(cat "$STATE/reboot_status")" == "PASSED" ]]
[[ "$(cat "$STATE/os_validation")" == "PASSED" ]]
[[ "$(cat "$STATE/kernel_validation")" == "PASSED" ]]
[[ "$(cat "$STATE/dns_resolution_status")" == "PASSED" ]]
[[ "$(cat "$STATE/dnf_transaction_validation")" == "PASSED" ]]
[[ "$(sha256sum /etc/resolv.conf | awk '{print $1}')" == "$RESOLV_BEFORE" ]]
echo "PASS: corrected post-reboot verification completes and marks the run VERIFIED."
echo "PASS: DNS resolver configuration was not modified during verification."
echo "PASS: all Rocky Linux 9 post-reboot verification integration scenarios."
