# synology-github-backup

Synology NAS shell script that backs up all owned GitHub repositories as ZIP snapshots.
Supports multiple accounts — the script auto-detects the authenticated login from each PAT
and uses it as the subfolder name.

## Output structure

```
/volume1/homes/Dominik/sourcecode/github/
  d-oit/
    repo-a.zip
    repo-b.zip
  d-o-hub/
    repo-x.zip
```

## Requirements

| Tool | Install |
|------|---------|
| `curl` | Built into DSM |
| `jq` | SynoCommunity or Entware |
| `mktemp` | Built into DSM |

## Setup

1. Copy `github_backup.sh` to `/volume1/homes/Dominik/sourcecode/github_backup.sh`
2. `chmod +x /volume1/homes/Dominik/sourcecode/github_backup.sh`
3. Create `/volume1/homes/Dominik/sourcecode/github_tokens.txt` from `github_tokens.txt.example`
4. Add to **DSM → Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**
   - User: `Dominik` (or a dedicated backup user)
   - Schedule: Daily
   - Run command: `/volume1/homes/Dominik/sourcecode/github_backup.sh`

## Fine-grained PAT permissions needed

- **Metadata**: Read-only (required for listing repos)
- **Contents**: Read-only (required for downloading zipballs)

## Notes

- Downloads **ZIP snapshots only** — no Git history.
- For a full disaster-recovery backup use `git clone --mirror` instead.
- Each run overwrites the previous ZIP for the same repo.
- Pagination is handled automatically (100 repos per page).
