#!/usr/bin/env bash
# Disposable Rocky Linux 9 integration test for offline_patch.sh.
set -Eeuo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/offline_patch.sh"
[[ -f "$SCRIPT" ]] || { echo "offline_patch.sh not found" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root inside the disposable test container" >&2; exit 1; }

dnf -y install bash dnf rpm-build createrepo_c dnf-plugins-core diffutils findutils grep sed gawk util-linux-core
WORK="$(mktemp -d /tmp/offline-patch-it.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
TOP="$WORK/rpmbuild"
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

build_test_rpm() {
    local version="$1"
    cat > "$TOP/SPECS/offline-patch-fixture.spec" <<EOF
Name: offline-patch-fixture
Version: $version
Release: 1
Summary: Disposable integration test package
License: MIT
BuildArch: noarch
%description
Disposable package used only by offline-patch integration tests.
%install
mkdir -p %{buildroot}/usr/share/offline-patch-fixture
echo "$version" > %{buildroot}/usr/share/offline-patch-fixture/version
%files
/usr/share/offline-patch-fixture/version
EOF
    rpmbuild --define "_topdir $TOP" -bb "$TOP/SPECS/offline-patch-fixture.spec" >/dev/null
    find "$TOP/RPMS" -type f -name "offline-patch-fixture-${version}-1.noarch.rpm" -print -quit
}

V1="$(build_test_rpm 1.0)"
V2="$(build_test_rpm 2.0)"
[[ -n "$V1" && -n "$V2" ]]
dnf -y install "$V1"

REPO="/usr/local/src/updates-integration-$RANDOM"
mkdir -p "$REPO"
cp "$V2" "$REPO/"
createrepo_c "$REPO" >/dev/null

HOST="$(hostname -s)"
STATE_BASE="/var/lib/offline-patching/$HOST"
STATE="$STATE_BASE/integration-upgrade"
mkdir -p "$STATE"
source /etc/os-release
printf '%s\n' DOWNLOADED > "$STATE/status"
printf '%s\n' "$REPO" > "$STATE/repo_dir"
printf '%s\n' "$ID" > "$STATE/os_id"
printf '%s\n' "${VERSION_ID%%.*}" > "$STATE/os_major"
printf '%s\n' "$(uname -m)" > "$STATE/arch"

(
    cd "$REPO"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS
    find . -type f ! -name SHA256SUMS -printf '%P\n' | sort
) > "$STATE/repository_file_list.txt"
sha256sum "$REPO/SHA256SUMS" | awk '{print $1}' > "$STATE/repository_manifest_hash"

echo "TEST 1: local-only upgrade and DNF preview"
printf 'yes\n' | "$SCRIPT" install
rpm -q offline-patch-fixture
[[ "$(rpm -q --qf '%{VERSION}' offline-patch-fixture)" == "2.0" ]]
[[ "$(cat "$STATE/status")" == "INSTALLED_PENDING_REBOOT" ]]
[[ -s "$STATE/dnf_transaction_preview.txt" ]]
[[ -s "$STATE/dnf_transaction_id" ]]
grep -q 'offline-patch-fixture' "$STATE/dnf_transaction_preview.txt"
echo "PASS: DNF preview, local-only package upgrade, RPM inventory and transaction ID."

echo "TEST 2: repository tamper detection"
TAMPER_REPO="/usr/local/src/updates-integration-tamper-$RANDOM"
cp -a "$REPO" "$TAMPER_REPO"
printf '%s\n' 'tampered' >> "$TAMPER_REPO/offline-patch-fixture-2.0-1.noarch.rpm"
TAMPER_STATE="$STATE_BASE/integration-tamper"
mkdir -p "$TAMPER_STATE"
printf '%s\n' DOWNLOADED > "$TAMPER_STATE/status"
printf '%s\n' "$TAMPER_REPO" > "$TAMPER_STATE/repo_dir"
printf '%s\n' "$ID" > "$TAMPER_STATE/os_id"
printf '%s\n' "${VERSION_ID%%.*}" > "$TAMPER_STATE/os_major"
printf '%s\n' "$(uname -m)" > "$TAMPER_STATE/arch"
cp "$STATE/repository_file_list.txt" "$TAMPER_STATE/repository_file_list.txt"
cp "$STATE/repository_manifest_hash" "$TAMPER_STATE/repository_manifest_hash"
set +e
"$SCRIPT" install </dev/null > "$WORK/tamper.log" 2>&1
tamper_rc=$?
set -e
cat "$WORK/tamper.log"
[[ $tamper_rc -ne 0 ]]
grep -Eq 'manifest hash mismatch|checksum validation failed|Repository file inventory changed' "$WORK/tamper.log"
echo "PASS: tampered local repository rejected before DNF transaction."
echo "ALL ROCKY LINUX 9 INTEGRATION TESTS PASSED."
