# Production validation and repository-scope review

This document records the operational checks required before using the framework on a production fleet. Passing CI is not equivalent to production certification.

## 1. Enabled repository scope

The download workflow uses DNF's enabled repositories to resolve and download updates. This can include vendor repositories and third-party repositories (for example, Docker CE or Kubernetes) when they are enabled on the host.

Each download run records the output of:

```bash
dnf repolist --enabled
```

The record is stored at:

```
/var/lib/offline-patching/<hostname>/<RUN_ID>/enabled_repositories.txt
```

It is also referenced by the execution report. Review this file before installation. Confirm that every repository is approved for the server role and patch window. Disable repositories that are not part of the intended patch scope before running `download`.

The installer itself uses `--disablerepo='*'` and installs only from the run's local repository. This prevents it from reaching enabled remote repositories during installation, but it does not narrow the package set already downloaded.

## 2. Manifest integrity boundary

The framework records SHA-256 checksums for repository files, stores the SHA-256 hash of the checksum manifest in the root-owned run-state directory, and verifies both the checksums and exact file inventory before installation.

This detects accidental corruption and repository-file changes when the stored state remains trusted. It is not a cryptographic authenticity guarantee against an attacker with root access: such an attacker could alter the repository, checksum manifest, and stored manifest hash together.

A signed manifest should only be added when there is a defined signing-key lifecycle and a verification trust anchor that is protected independently of the patch repository and run-state directory. Do not treat a key stored beside the repository as protection against a privileged local attacker.

## 3. Disposable Rocky Linux 9 VM reboot test

CI exercises the lifecycle in disposable Rocky Linux 9 containers and simulates a changed boot ID in its verification harness. Containers do not perform a real kernel reboot, so a disposable VM test remains required.

Use a VM snapshot and a non-production host with the same repository configuration and storage layout intended for deployment.

1. Confirm OS release, architecture, enabled repositories, current kernel, and free disk space.
2. Run `download`; review the saved enabled-repository list, RPM inventory, and generated report.
3. Run `install`; inspect the DNF preview and explicitly approve the transaction.
4. Confirm the lifecycle is `INSTALLED_PENDING_REBOOT`; do not assume the framework will reboot automatically.
5. Reboot the VM using the normal operating procedure.
6. Run `verify`; confirm the boot ID changed, running kernel matches the expected default kernel, OS identity is unchanged, DNS resolves, and the DNF transaction is present.
7. Run `report` and retain the report and run log.
8. Repeat with a no-op update cycle and, if practical, a deliberately interrupted download on a disposable snapshot.

Record the VM image, OS minor version, kernel before/after, repository list, DNF transaction ID, and any deviations.

## 4. Representative-host operational test

Before fleet use, run the same workflow on one representative non-critical server. Validate the actual mirrors, proxy/subscription setup, third-party repository policy, disk capacity, service health, reboot window, and application health checks. A successful DNF transaction and framework verification do not replace application-level validation.

## 5. Current qualification boundary

- Automated CI validates shell syntax, ShellCheck, DNF local-repository behavior, download lifecycle, interrupted-run recovery, and post-reboot verification logic.
- CI runs in Rocky Linux 9 containers; the verification harness simulates reboot state.
- A real VM reboot and representative-host operational test have not been performed by CI.
- RPM GPG signature verification remains explicitly out of scope for the current iteration.
- Do not describe the framework as production-certified until the VM and representative-host checks have been completed and reviewed.
