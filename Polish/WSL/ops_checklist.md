# WSL Runner Ops Checklist

- Never open or run Unity builds from a dirty shared checkout.
- WSL and PowerShell agents must not edit the same checkout; avoid /mnt/c edits.
- Use disposable worktrees for jobs and delete them afterward.
