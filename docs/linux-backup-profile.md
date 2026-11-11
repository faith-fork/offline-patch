# Linux baseline backup profile

The Linux profile captures a pre-change and post-change operational baseline. It is intended for configuration auditing and change comparison, not disaster recovery or automatic rollback.

## Commands

Run before patching:

```bash
sudo bash offline_patch.sh backup linux --phase pre
```

Run after patching and rebooting:

```bash
sudo bash offline_patch.sh backup linux --phase post
```

The post phase pairs with the outstanding pre phase for the same host. Only one unmatched pre phase is allowed at a time. The pair is retained and the latest-pre pointer is cleared after a successful comparison.

## Storage

Backups are written below:

```
/var/lib/offline-patching/<hostname>/linux-backups/<BACKUP_ID>/
```

Each phase contains:
- `system-inventory.txt`: OS identity, kernel, RPM inventory.
- `network-storage.txt`: addresses, routes, NetworkManager connection listing, mounts, block devices and filesystem usage.
- `services-security.txt`: systemd unit/timer state, failed units, firewalld rules, account/group listings and root crontab.
- `etc-config.tar.gz`: selected system configuration paths, preserving numeric ownership, ACLs and extended attributes.
- `SHA256SUMS`: checksum manifest for the captured phase files.

The comparison directory contains text diffs for system inventory, network/storage and services/security, plus `comparison-report.txt`.

## Security and operational boundaries

- The backup root and backup set directories are mode 0700. Files are created under the script's restrictive umask.
- Archives can contain credentials, private keys, network secrets and other sensitive configuration. Keep the backup filesystem protected and encrypted at rest according to local policy.
- The profile does not capture application data, databases, container volumes, Kubernetes etcd, MinIO object data or external service state.
- It does not restore configuration automatically. Do not extract an archive over a live system as a rollback procedure.
- A checksum manifest detects accidental corruption only while the manifest itself remains trusted. It is not a signature or protection against a privileged local attacker.
- Validate backup contents and retention policy before production rollout. Consider copying completed backup sets to a separate protected backup destination; the current profile stores them locally.
- Some commands are optional on minimal hosts. Their output records an error or empty result rather than stopping the capture. Review each baseline for completeness.

## Recommended patch workflow

1. Capture pre-patch baseline.
2. Review the backup directory and confirm the configuration archive is readable.
3. Run the offline patch download/install workflow.
4. Reboot during the approved maintenance window.
5. Run the framework's OS verification.
6. Capture the post-patch baseline.
7. Review `comparison-report.txt` and the three diff files.
8. Perform application-specific health checks independently.
