#!/usr/bin/env bash
# Disposable Rocky Linux 9 download-workflow integration tests. CI container only.
set -Eeuo pipefail

SCRIPT="${GITHUB_WORKSPACE:-$(pwd)}/offline_patch.sh"
WORK="$(mktemp -d /tmp/offline-patch-download.XXXXXX)"
STATE_BASE="/var/lib/offline-patching"
HOST="$(hostname -s)"
STATE_ROOT="$STATE_BASE/$HOST"
BUILD="$WORK/rpmbuild"
REAL_DNF="$(command -v dnf)"
REPO_FILE="/etc/yum.repos.d/offline-patch-ci.repo"
REPO_BACKUP="$WORK/yum.repos.d"
CREATED_STATES=()
CREATED_REPOS=()

cleanup() {
  rm -rf "$WORK" "$REPO_FILE"
  if [[ -d "$REPO_BACKUP" ]]; then
    rm -rf /etc/yum.repos.d
    mv "$REPO_BACKUP" /etc/yum.repos.d
  fi
  local path
  for path in "${CREATED_STATES[@]}"; do
    [[ -f "$path/run_id" ]] && rm -f "/root/rpm_inventory_$(cat "$path/run_id").txt"
    rm -rf "$path"
  done
  for path in "${CREATED_REPOS[@]}"; do rm -rf "$path"; done
}
trap cleanup EXIT

for cmd in dnf rpm rpmbuild createrepo_c sha256sum awk sort find hostname uname getent; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing test prerequisite: $cmd"; exit 1; }
done

[[ $EUID -eq 0 ]] || { echo "Run this integration test as root."; exit 1; }
source /etc/os-release
[[ "$ID" == rocky && "${VERSION_ID%%.*}" == 9 ]] || { echo "This test requires Rocky Linux 9."; exit 1; }

mkdir -p "$BUILD"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$STATE_ROOT"
mv /etc/yum.repos.d "$REPO_BACKUP"
mkdir -p /etc/yum.repos.d

cat > "$BUILD/SPECS/offline-patch-download-fixture.spec" <<'SPEC'
Name: offline-patch-download-fixture
Version: %{?fixture_version}
Release: 1%{?dist}
Summary: Disposable package for download workflow tests
License: MIT
BuildArch: noarch

%description
Disposable fixture package for offline-patch download integration tests.

%install
mkdir -p %{buildroot}/usr/share/offline-patch-download-fixture
printf '%s\n' '%{version}' > %{buildroot}/usr/share/offline-patch-download-fixture/version.txt

%files
/usr/share/offline-patch-download-fixture/version.txt
SPEC

build_fixture() {
  local version="$1"
  rpmbuild --define "_topdir $BUILD" --define "fixture_version $version" -bb "$BUILD/SPECS/offline-patch-download-fixture.spec" >/dev/null
  printf '%s\n' "$BUILD/RPMS/noarch/offline-patch-download-fixture-$version-1.el9.noarch.rpm"
}

make_repo() {
  local repo="$1" rpm_file="$2"
  mkdir -p "$repo"
  cp "$rpm_file" "$repo/"
  createrepo_c "$repo" >/dev/null
}

set_enabled_repo() {
  local repo="$1"
  cat > "$REPO_FILE" <<EOF
[offline-patch-ci]
name=Offline patch CI fixture repository
baseurl=file://$repo
enabled=1
gpgcheck=0
metadata_expire=0
EOF
  "$REAL_DNF" clean all >/dev/null
  "$REAL_DNF" makecache --refresh >/dev/null
}

run_download() {
  local output="$1"
  shift
  set +e
  printf 'root\n' | "$@" bash "$SCRIPT" download > "$output" 2>&1
  local rc=$?
  set -e
  cat "$output"
  return "$rc"
}

newest_state() {
  find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f %p\n' |
    sort -r | head -n1 | cut -d' ' -f2-
}

# Baseline fixture v1, with v2 available in the only enabled repository.
rpm_v1="$(build_fixture 1.0)"
rpm_v2="$(build_fixture 2.0)"
rpm_v3="$(build_fixture 3.0)"
rpm -Uvh --quiet "$rpm_v1"
repo_v2="$WORK/repo-v2"
make_repo "$repo_v2" "$rpm_v2"
CREATED_REPOS+=("$repo_v2")
set_enabled_repo "$repo_v2"

# 1. Download-only must capture updates without installing them.
before_inventory="$WORK/rpm-before.txt"
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$before_inventory"
run_download "$WORK/download-success.log"
state_success="$(newest_state)"
CREATED_STATES+=("$state_success")
repo_success="$(cat "$state_success/repo_dir")"

[[ "$(cat "$state_success/status")" == "DOWNLOADED" ]]
[[ "$(cat "$state_success/rpm_count")" == "1" ]]
[[ -f "$repo_success/$(basename "$rpm_v2")" ]]
[[ "$(rpm -q --qf '%{VERSION}' offline-patch-download-fixture)" == "1.0" ]]
cmp -s "$before_inventory" "$state_success/rpm_inventory.txt"
[[ -s "/root/rpm_inventory_$(cat "$state_success/run_id").txt" ]]
(
  cd "$repo_success"
  sha256sum --check SHA256SUMS
  find . -type f ! -name SHA256SUMS -printf '%P\n' | sort
) > "$WORK/repo-verified-files.txt"
cmp -s "$state_success/repository_file_list.txt" "$WORK/repo-verified-files.txt"
[[ "$(sha256sum "$repo_success/SHA256SUMS" | awk '{print $1}')" == "$(cat "$state_success/repository_manifest_hash")" ]]
grep -q '^repodata/' "$state_success/repository_file_list.txt"
grep -q '^REPOSITORY_INFO.txt$' "$state_success/repository_file_list.txt"
echo "PASS: download-only fetched the enabled-repository update without installing it."
echo "PASS: repository metadata, SHA256 manifest, file inventory and RPM inventory were created and verified."

# 2. Install the fixture update, then verify a subsequent download records NO_UPDATES.
rpm -Uvh --quiet "$repo_success/$(basename "$rpm_v2")"
run_download "$WORK/no-updates.log"
state_no_updates="$(newest_state)"
CREATED_STATES+=("$state_no_updates")
[[ "$(cat "$state_no_updates/status")" == "NO_UPDATES" ]]
[[ "$(cat "$state_no_updates/rpm_count")" == "0" ]]
[[ ! -e "$(cat "$state_no_updates/repo_dir")/SHA256SUMS" ]]
echo "PASS: zero available updates records NO_UPDATES without creating a repository manifest."

# 3. Inject a failure specifically at the download-only transaction and check recovery state.
repo_v3="$WORK/repo-v3"
make_repo "$repo_v3" "$rpm_v3"
CREATED_REPOS+=("$repo_v3")
set_enabled_repo "$repo_v3"
wrapper="$WORK/mock-bin"
mkdir -p "$wrapper"
cat > "$wrapper/dnf" <<'WRAPPER'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "--downloadonly" ]]; then
    echo "Injected interrupted download for integration test" >&2
    exit 42
  fi
done
exec "$REAL_DNF" "$@"
WRAPPER
chmod +x "$wrapper/dnf"

set +e
run_download "$WORK/interrupted-download.log" env REAL_DNF="$REAL_DNF" PATH="$wrapper:$PATH"
download_rc=$?
set -e
[[ "$download_rc" -ne 0 ]]
state_failed="$(newest_state)"
CREATED_STATES+=("$state_failed")
[[ "$(cat "$state_failed/status")" == "FAILED" ]]
[[ -s "$state_failed/rpm_inventory.txt" ]]
[[ -s "$state_failed/run.log" ]]
[[ "$(rpm -q --qf '%{VERSION}' offline-patch-download-fixture)" == "2.0" ]]
echo "PASS: interrupted download is marked FAILED, retains diagnostics/inventory, and leaves installed packages unchanged."

echo "PASS: all Rocky Linux 9 download-workflow integration scenarios."
