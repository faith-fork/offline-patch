# Offline Patch Management

`offline_patch.sh` manages offline patching for a single Rocky Linux, RHEL, AlmaLinux, or Oracle Linux server running major version 8 or 9. It downloads updates while enabled DNF repositories are reachable, stores the RPMs and repository metadata on that server, and installs from that local repository with all other repositories disabled.

## Requirements

- Run the script as `root` (for example, with `sudo`).
- The server must use DNF4 and have working enabled DNF repositories during the download phase.
- The download phase needs `createrepo_c` and `dnf-plugins-core`; the script installs them with DNF if they are missing.
- Set `DNS_TEST_NAME` near the top of the script to a hostname that should resolve after reboot. Use an internal hostname for an internal-only environment.
- Ensure the user running the download command can be resolved locally and has a valid home directory; the script saves the RPM inventory there.

The default RPM repository path is `/usr/local/src`. Run state and reports are stored under `/var/lib/offline-patching/<hostname>`. A lock file prevents two copies of this script from running at the same time.

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

4. View a run's report:

   ```bash
   sudo ./offline_patch.sh report
   ```

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
