#!/usr/bin/env bash
# Disposable Rocky Linux 9 integration test for offline_patch.sh.
# Runs only inside an ephemeral CI container; never use on a production host.
set -Eeuo pipefail

SCRIPT="${GITHUB_WORKSPACE:-$(pwd)}/offline_patch.sh"
WORK="$(mktemp -d /tmp/offline-patch-it.XXXXXX)"
STATE_BASE="/var/lib/offline-patching"
HOST="$(hostname -s)"
RUN_ID="ci-integration-$$"
STATE="$STATE_BASE/$HOST/$RUN_ID"
REPO="$WORK/repo"
BUILD="$WORK/rpmbuild"

cleanup() {
  rm -rf "$WORK" "$STATE"
}
trap cleanup EXIT

for cmd in dnf rpm rpmbuild createrepo_c sha256sum awk sort find hostname uname; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing test prerequisite: $cmd"; exit 1; }
done

mkdir -p "$BUILD"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$REPO" "$STATE"
cat > "$BUILD/SPECS/offline-patch-fixture.spec" <<'SPEC'
Name: offline-patch-fixture
Version: %{?fixture_version}
Release: 1%{?dist}
Summary: Disposable package used by offline patch integration tests
License: MIT
BuildArch: noarch

%description
Disposable fixture package for the offline-patch CI integration test.

%install
mkdir -p %{buildroot}/usr/share/offline-patch-fixture
printf '%s\n' '%{version}' > %{buildroot}/usr/share/offline-patch-fixture/version.txt

%files
/usr/share/offline-patch-fixture/version.txt
SPEC

rpmbuild --define "_topdir $BUILD" --define "fixture_version 1.0" -bb "$BUILD/SPECS/offline-patch-fixture.spec"
dnf install -y "$BUILD/RPMS/noarch/offline-patch-fixture-1.0-1"*.rpm
rpmbuild --define "_topdir $BUILD" --define "fixture_version 2.0" -bb "$BUILD/SPECS/offline-patch-fixture.spec"
cp "$BUILD/RPMS/noarch/offline-patch-fixture-2.0-1"*.rpm "$REPO/"
createrepo_c "$REPO"

(
  cd "$REPO"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS
)
sha256sum "$REPO/SHA256SUMS" | awk '{print $1}' > "$STATE/repository_manifest_hash"
(
  cd "$REPO"
  find . -type f ! -name SHA256SUMS -printf '%P\n' | sort
) > "$STATE/repository_file_list.txt"

# Match the state format consumed by select_state()/install_updates().
source /etc/os-release
printf '%s\n' DOWNLOADED > "$STATE/status"
printf '%s\n' "$REPO" > "$STATE/repo_dir"
printf '%s\n' "$ID" > "$STATE/os_id"
printf '%s\n' "${VERSION_ID%%.*}" > "$STATE/os_major"
printf '%s\n' "$(uname -m)" > "$STATE/arch"
printf '%s\n' 1 > "$STATE/rpm_count"
printf '%s\n' CREATED > "$STATE/repository_checksum_status"

echo "yes" | bash "$SCRIPT" install

installed_version="$(rpm -q --qf '%{VERSION}' offline-patch-fixture)"
[[ "$installed_version" == "2.0" ]] || {
  echo "Expected fixture package version 2.0; got $installed_version"
  exit 1
}
[[ "$(cat "$STATE/status")" == "INSTALLED_PENDING_REBOOT" ]] || {
  echo "Expected lifecycle status INSTALLED_PENDING_REBOOT"
  exit 1
}
[[ -s "$STATE/dnf_transaction_preview.txt" ]] || {
  echo "DNF transaction preview was not recorded"
  exit 1
}
[[ -s "$STATE/packages_added.txt" ]] || {
  echo "Package change inventory was not recorded"
  exit 1
}
echo "PASS: local-only DNF upgrade, transaction preview, inventory and state transitions."
