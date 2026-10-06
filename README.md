# Windows System Health Toolkit

A PowerShell system-health and maintenance utility built around **drive-aware diagnostics, safer repair choices and technician reporting**.

## The problem

Windows maintenance scripts can become risky when they assume every volume should be treated the same way. A repair action that is appropriate for the Windows system drive may be inappropriate for a removable or data drive.

## The approach

The toolkit detects the Windows system volume, inventories available fixed/removable drives and labels their protection state before disk operations are run.

A key safety behavior in the current script is that repair requests against non-system data drives are converted to read-only diagnostic checks instead of automatically sending repair switches.

## Core capabilities

- Windows system-drive detection
- Fixed/removable drive inventory
- Explicit drive selection
- Protected non-system drive behavior
- CHKDSK diagnostic and repair workflows
- Session transcripts
- Timestamped report paths
- Administrator-aware execution
- Repository-backed remote PowerShell launch path

## Safety model

The project distinguishes between:

- **System drive** — repair operations may be offered where appropriate.
- **Non-system data/removable drives** — protected by default and treated as diagnostic targets unless deliberately redesigned otherwise.

This does not eliminate risk. Always review the script and keep backups before running system or disk servicing commands.

## Requirements

- Windows
- Windows PowerShell 5.1 or newer
- Administrator privileges for servicing actions that require them

## Remote launch

The script contains a repository-backed launch path so it can be invoked from an elevated PowerShell session.

Review remote scripts before execution and only run code from sources you trust.

## Design principles

1. Detect before acting.
2. Make the target drive explicit.
3. Prefer read-only behavior for non-system data volumes.
4. Record useful output for later review.
5. Fail visibly rather than silently changing system state.

## Roadmap

- Add structured tests around drive-selection and failure states.
- Improve operator-facing summaries before destructive actions.
- Expand diagnostic reporting.
- Define the feature boundary between this focused toolkit and the broader Windows Maintenance Toolkit.
- Add release/version documentation.

## Portfolio case study

**https://T3ND41.github.io/portfolio/projects/system-health.html**

## License

See the repository's `LICENSE` file.
