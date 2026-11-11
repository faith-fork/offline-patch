#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE_BASE="$TMP/state"
HOST="backup-test-host"
source "$ROOT/lib/linux_backup.sh"
log(){ printf '[test] %s\n' "$*"; }
die(){ printf '[expected/error] %s\n' "$*" >&2; exit 1; }

# Deterministic harmless command stubs; tar/find/diff/checksum remain real.
hostnamectl(){ echo "Test Linux host"; }
ip(){ echo "test-interface UP 192.0.2.10/24"; }
nmcli(){ echo "test-connection"; }
findmnt(){ echo "/dev/test / ext4 rw"; }
lsblk(){ echo "test-disk"; }
df(){ echo "filesystem size used avail use mount"; }
systemctl(){ echo "test.service enabled"; }
firewall-cmd(){ echo "test firewall"; }
getent(){ echo "test account"; }
crontab(){ echo "no crontab"; }
rpm(){ echo "test-package-1.0-1.el9.x86_64"; }

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

# Post without a pre-capture must fail safely.
if (linux_backup linux --phase post >/dev/null 2>&1); then fail "post without pre was accepted"; fi
pass "post without pre rejected"

linux_backup linux --phase pre
BACKUP_ROOT="$(linux_backup_root)"
BACKUP_ID="$(cat "$BACKUP_ROOT/latest_pre")"
TARGET="$BACKUP_ROOT/$BACKUP_ID"
[[ -d "$TARGET/pre" ]] || fail "pre capture directory missing"
[[ "$(stat -c '%a' "$BACKUP_ROOT")" == 700 ]] || fail "backup root permissions are not 0700"
[[ "$(stat -c '%a' "$TARGET")" == 700 ]] || fail "backup set permissions are not 0700"
[[ -s "$TARGET/pre/etc-config.tar.gz" ]] || fail "configuration archive missing"
[[ -s "$TARGET/pre/SHA256SUMS" ]] || fail "pre checksums missing"
( cd "$TARGET/pre" && sha256sum --check SHA256SUMS >/dev/null ) || fail "pre checksums invalid"
pass "pre capture, restrictive permissions, archive and checksums"

# A second pre must not orphan/replace the outstanding pair.
if (linux_backup linux --phase pre >/dev/null 2>&1); then fail "second unmatched pre was accepted"; fi
[[ "$(cat "$BACKUP_ROOT/latest_pre")" == "$BACKUP_ID" ]] || fail "unmatched pre pointer changed"
pass "duplicate unmatched pre rejected"

rpm(){ echo "test-package-2.0-1.el9.x86_64"; }
linux_backup linux --phase post
[[ -d "$TARGET/post" ]] || fail "post capture directory missing"
[[ -s "$TARGET/comparison-report.txt" ]] || fail "comparison report missing"
grep -q 'test-package-1.0' "$TARGET/system-inventory.diff" || fail "pre package missing from diff"
grep -q 'test-package-2.0' "$TARGET/system-inventory.diff" || fail "post package missing from diff"
[[ -s "$TARGET/system-inventory.diff" ]] || fail "expected inventory diff empty"
[[ ! -e "$BACKUP_ROOT/latest_pre" ]] || fail "latest_pre pointer not cleared"
[[ "$(cat "$BACKUP_ROOT/latest_completed")" == "$BACKUP_ID" ]] || fail "completed pointer incorrect"
( cd "$TARGET/post" && sha256sum --check SHA256SUMS >/dev/null ) || fail "post checksums invalid"
pass "post capture, comparison, package delta and checksums"

if (linux_backup linux --phase post >/dev/null 2>&1); then fail "repeated post was accepted"; fi
pass "repeated post rejected"
echo "All Linux backup tests passed."
