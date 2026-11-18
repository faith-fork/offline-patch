# Offline Patch Management

`offline_patch.sh` manages offline patching for a single Rocky Linux, RHEL, AlmaLinux, or Oracle Linux server running major version 8 or 9, and Rocky Linux 10. The script downloads updates while enabled DNF repositories are reachable, stores the RPMs and repository metadata on that server, and installs from that local repository with all other repositories disabled.

## Requirements

- Run the script as `root` (for example, with `sudo`).
- The server must use DNF4 and have working enabled DNF repositories during the download phase.
- The download phase needs `createrepo_c` and `dnf-plugins-core`; the script installs them with DNF if they are missing.
- Set `DNS_TEST_NAME` near the top of the script to a hostname that should resolve after reboot. Use an internal hostname for an internal-only environment.
- Ensure the user running the download command can be resolved locally and has a valid home directory; the script saves the RPM inventory there.

## Rocky Linux 10 support

Rocky Linux 10 is supported. The script requires DNF4 and rejects DNF5. On `x86_64`, it checks the dynamic loader's reported x86-64-v3 capability, which accounts for the CPU feature names exposed by the host.

This does not add support for RHEL, AlmaLinux, or Oracle Linux 10. Rocky Linux does not support an in-place major upgrade from 8 or 9 to 10; use a fresh OS installation for that transition. See the [Rocky Linux 10 release notes](https://docs.rockylinux.org/latest/releases/release_notes/10_0/) and [Rocky release lifecycle](https://docs.rockylinux.org/releases/).

The default RPM repository path is `/usr/local/src`. Run state and reports are stored under `/var/lib/offline-patching/<hostname>`. A lock file prevents two copies of this script from running at the same time.

Before downloading updates, the script asks DNF for a transaction-size estimate without applying it, then checks free space on the filesystems containing the selected package repository and run-state directory. The repository filesystem must have the estimated download size plus a 30% buffer and a 1 GiB reserve; the run-state filesystem must have at least 512 MiB free. These defaults can be adjusted near the top of the script. The check is recorded in the text and HTML reports, along with its estimate and available space. A later process can still consume space, so this is a preflight estimate rather than a guarantee.

## Linux pre-patch baseline

Before installing or recovering packages, the script records a root-only Linux baseline in the selected run's state directory. It archives selected host, DNS, network, storage, firewall, sysctl, and boot configuration from `/etc`, and captures host/kernel identity, `df -hT`, `lsblk`, `/etc/fstab`, resolved fstab entries, `pvs`, `vgs`, `lvs` when LVM tools are installed, mount points, IP addresses, IPv4 and IPv6 routes, policy rules, active NetworkManager connections (when available), failed systemd units, and the default target.

After reboot, `verify` captures those command outputs again and writes a recursive comparison to `linux_baseline_diff.txt`. It also generates `patch_execution_report.html` with the pre-patch and post-reboot outputs side by side, a color-highlighted diff (green additions, red removals), and verification details. The HTML report is generated when the text report is generated and can be refreshed with `sudo ./offline_patch.sh report`. Differences are a review aid: expected package changes and dynamic state can appear, so they are not an automatic pass/fail criterion. The baseline archive is not automatically restored. Artifacts are stored locally under `/var/lib/offline-patching/<hostname>` with restrictive permissions; copy them to secure external storage if they must survive server or disk loss. Configuration files and network output can contain sensitive information.

MinIO configuration, IAM, bucket metadata, and object data are outside this Linux baseline and will be handled separately. The Linux verification does not claim to validate MinIO service behavior.

## Standard workflow

1. Download updates while repositories are available:

   ```bash
   sudo ./offline_patch.sh download
   ```

   The script asks for a Linux username for the RPM inventory, checks enabled repositories, downloads available updates, builds local repository metadata, and writes a checksum manifest.

2. Install from the local repository:

   ```bash
   sudo ./offline_patch.sh install
   ```

   Review the selected run and confirm the install when prompted. The script disables all configured repositories and uses only the saved local repository.

3. Reboot the server during the approved maintenance window, then verify:

   ```bash
   sudo reboot
   # After the server returns:
   sudo ./offline_patch.sh verify
   ```

4. View a run's reports:

   ```bash
   sudo ./offline_patch.sh report
   ```

   The command displays the text report and writes `patch_execution_report.html` in the selected run directory. Open that HTML file in a browser to review the pre/post comparison.

## Inspecting and recovering a run

List available run details and view any recorded failure:

```bash
sudo ./offline_patch.sh inspect
```

For a run interrupted during package installation, use:

```bash
sudo ./offline_patch.sh recover
```

Recovery checks the saved repository checksums, OS identity and architecture, RPM database, and DNF package consistency. It then asks before rerunning the DNF upgrade using only that run's local repository. This is a guarded retry and reconciliation step; it does not replay or resume the original DNF transaction. Review the run's report and error, and do not proceed if the checks fail or the package state is unclear. If DNF reports another active package-management process, wait for it to finish before retrying.

The script also marks an explicit decline at the install confirmation prompt as `CANCELLED`. A cancelled run was not installed; start a new download to create a new installable run.

## Commands

| Command | Purpose |
| --- | --- |
| `download` | Check repositories and download updates into a local repository. |
| `install` | Install updates from a selected local repository. |
| `verify` | Check reboot, OS, kernel, DNS, and DNF transaction state after installation. |
| `report` | Generate and display a selected run's report. |
| `inspect` | Show a selected run's state, failure details, and recovery guidance. |
| `recover` | Validate and retry an interrupted local package installation. |

Run without a valid command to display usage:

```bash
sudo ./offline_patch.sh
```
