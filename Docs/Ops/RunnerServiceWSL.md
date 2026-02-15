# Runner Service WSL Ownership Recovery (Buildbox)

## Problem Signature

If workflow preflight logs show `wsl_distro_count=0` or `wsl_no_distros`, but manual preflight from an interactive shell shows distros, the lane is running under the wrong Windows service account.

Typical symptom pattern:
- GitHub Actions preflight: `wsl_distro_count=0` / `wsl_no_distros`
- Interactive `wsl -l -q`: one or more distros listed

## Root Cause

WSL distros are per-user. If the GitHub runner Windows service runs as a different account (for example `NETWORK SERVICE`) than the account that owns the distros, workflow jobs cannot see or use those distros.

## Verification Checklist

1. **Service account**
   - Check runner service `StartName`.
   - Confirm it matches the expected desktop/service user (for example `.\Moni`).

2. **Workflow preflight evidence**
   - Preflight output must report `wsl_distro_count > 0`.
   - `wsl_no_distros` must not appear.

3. **WSL visibility in service context**
   - Run `wsl -l -q` under the same account used by the service.
   - Confirm expected distro list is present.

## Minimal Recovery Steps

1. Set runner service logon account to the correct user that owns the target WSL distro(s).
2. If service start fails with logon rights error, grant **Log on as a service** (`SeServiceLogonRight`) for that user.
3. Restart the runner service.
4. Trigger one smoke run.
5. Confirm preflight now shows WSL distros and lane proceeds beyond preflight.

## Fast Triage Cues

- **Preflight says no distros, but interactive shell has distros** -> service account mismatch.
- **Service refuses to start after logon change** -> missing `SeServiceLogonRight`.

## Do Not Do

Do **not** reinstall WSL, Unity, or the whole runner for this failure class first. This class is usually account ownership and service rights, not binary corruption.
