#!/usr/bin/env bash
# Disposable Rocky Linux 9 integration tests. CI container only.
set -Eeuo pipefail

SCRIPT="${GITHUB_WORKSPACE:-$(pwd)}/offline_patch.sh"
WORK="$(mktemp -d /tmp/offline-patch-it.XXXXXX)"
STATE_BASE="/var/lib/offline-patching"
HOST="$(hostname -s)"
RUN_ID="ci-integration-$$"
STATE_ROOT="$STATE_BASE/$HOST"
BUILD="$WORK/rpmbuild"
REAL_DNF="$(command -v dnf)"
mkdir -p "$BUILD"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$STATE_ROOT"

cleanup() {
  rm -rf "$WORK" "$STATE_ROOT/$RUN_ID"* 
}
trap cleanup EXIT

for cmd in dnf rpm rpmbuild createrepo_c sha256sum awk sort find hostname uname; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing test prerequisite: $cmd"; exit 1; }
done

source /etc/os-release
OS_MAJOR="${VERSION_ID%%.*}"
ARCH="$(uname -m)"

cat > "$BUILD/SPECS/offline-patch-fixture.spec" <<'SPEC'
Name: offline-patch-fixture
Version: %{?fixture_version}
Release: 1%{?dist}
Summary: Disposable package used by offline-patch integration tests
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

build_fixture() {
  local version="$1"
  rpmbuild --define "_topdir $BUILD" --define "fixture_version $version" -bb "$BUILD/SPECS/offline-patch-fixture.spec" >/dev/null
  printf '%s\n' "$BUILD/RPMS/noarch/offline-patch-fixture-$version-1.el9.noarch.rpm"
}

make_repo() {
  local repo="$1" rpm_file="$2"
  mkdir -p "$repo"
  cp "$rpm_file" "$repo/"
  createrepo_c "$repo" >/dev/null
}

make_state() {
  local state="$1" repo="$2"
  mkdir -p "$state"
  (
    cd "$repo"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS
    find . -type f ! -name SHA256SUMS -printf '%P\n' | sort
  ) > "$state/repository_file_list.txt"
  sha256sum "$repo/SHA256SUMS" | awk '{print $1}' > "$state/repository_manifest_hash"
  printf '%s\n' DOWNLOADED > "$state/status"
  printf '%s\n' "$repo" > "$state/repo_dir"
  printf '%s\n' "$ID" > "$state/os_id"
  printf '%s\n' "$OS_MAJOR" > "$state/os_major"
  printf '%s\n' "$ARCH" > "$state/arch"
  printf '%s\n' 1 > "$state/rpm_count"
  printf '%s\n' CREATED > "$state/repository_checksum_status"
}

expect_install_failure() {
  local expected_status="$1"
  set +e
  echo yes | bash "$SCRIPT" install > "$WORK/expected-failure.log" 2>&1
  local rc=$?
  set -e
  cat "$WORK/expected-failure.log"
  [[ "$rc" -ne 0 ]] || { echo "Expected install to fail"; exit 1; }
  [[ "$(cat "$CURRENT_STATE/status")" == "$expected_status" ]] || {
    echo "Expected state $expected_status; got $(cat "$CURRENT_STATE/status")"
    exit 1
  }
}

# Establish a known baseline package version.
rpm_v1="$(build_fixture 1.0)"
dnf install -y "$rpm_v1" >/dev/null
rpm_v2="$(build_fixture 2.0)"
repo_v2="$WORK/repo-v2"
make_repo "$repo_v2" "$rpm_v2"

# 1. Repository tampering must block installation before DNF changes packages.
CURRENT_STATE="$STATE_ROOT/$RUN_ID-tamper"
make_state "$CURRENT_STATE" "$repo_v2"
printf 'tamper' >> "$repo_v2/$(basename "$rpm_v2")"
expect_install_failure "DOWNLOADED"
rpm -q --qf '%{VERSION}' offline-patch-fixture | grep -qx '1.0'
echo "PASS: repository tampering is detected and installation is blocked."
# Restore the repository package and its manifest for the legitimate install.
cp "$rpm_v2" "$repo_v2/"
make_state "$CURRENT_STATE" "$repo_v2"

# 2. A valid local repository upgrades the fixture package.
echo yes | bash "$SCRIPT" install
[[ "$(rpm -q --qf '%{VERSION}' offline-patch-fixture)" == "2.0" ]]
[[ "$(cat "$CURRENT_STATE/status")" == "INSTALLED_PENDING_REBOOT" ]]
[[ -s "$CURRENT_STATE/dnf_transaction_preview.txt" ]]
[[ -s "$CURRENT_STATE/packages_added.txt" ]]
echo "PASS: local-only DNF upgrade, preview, inventory and lifecycle transition."

# 3. A second local repository with the installed version must not request reboot.
repo_noop="$WORK/repo-noop"
make_repo "$repo_noop" "$rpm_v2"
CURRENT_STATE="$STATE_ROOT/$RUN_ID-noop"
make_state "$CURRENT_STATE" "$repo_noop"
echo yes | bash "$SCRIPT" install
[[ "$(cat "$CURRENT_STATE/status")" == "NO_CHANGES" ]]
[[ "$(cat "$CURRENT_STATE/reboot_required")" == "NO" ]]
[[ ! -s "$CURRENT_STATE/packages_added.txt" ]]
[[ ! -s "$CURRENT_STATE/packages_removed.txt" ]]
echo "PASS: no-op DNF transaction records NO_CHANGES and no reboot requirement."

# 4. Simulate a DNF install-stage failure; state must become FAILED.
rpm_v3="$(build_fixture 3.0)"
repo_v3="$WORK/repo-v3"
make_repo "$repo_v3" "$rpm_v3"
CURRENT_STATE="$STATE_ROOT/$RUN_ID-failed"
make_state "$CURRENT_STATE" "$repo_v3"
wrapper="$WORK/mock-bin"
mkdir -p "$wrapper"
cat > "$wrapper/dnf" <<'WRAPPER'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "-y" ]]; then
    printf '%s\n' "Injected DNF transaction failure for integration test" >&2
    exit 42
  fi
done
exec "$REAL_DNF" "$@"
WRAPPER
chmod +x "$wrapper/dnf"
set +e
echo yes | REAL_DNF="$REAL_DNF" PATH="$wrapper:$PATH" bash "$SCRIPT" install > "$WORK/failed-transaction.log" 2>&1
failure_rc=$?
set -e
cat "$WORK/failed-transaction.log"
[[ "$failure_rc" -ne 0 ]]
[[ "$(cat "$CURRENT_STATE/status")" == "FAILED" ]]
[[ "$(rpm -q --qf '%{VERSION}' offline-patch-fixture)" == "2.0" ]]
echo "PASS: failed DNF transaction leaves FAILED state and does not upgrade fixture RPM."

echo "PASS: all Rocky Linux 9 offline-patch integration scenarios."
