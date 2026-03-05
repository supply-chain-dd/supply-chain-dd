# Gitea Repositories

This directory contains pre-configured repository definitions for CTF challenges.

## Usage

Place Git repositories here that will be imported into Gitea for participants to work with.

## Example Structure

```
repos/
├── challenge-1/
│   ├── .git/
│   ├── README.md
│   └── src/
└── challenge-2/
    └── ...
```

## Importing Repositories

Repositories can be imported into Gitea using:

1. **Gitea Web UI**: Admin Panel → Repository Management → Migrate Repository
2. **Gitea API**: Use the API to programmatically create repositories
3. **Git CLI**: Clone from local path and push to Gitea

Example using Gitea API:
```bash
curl -X POST "http://localhost:30002/api/v1/repos/migrate" \
  -H "Authorization: token YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clone_addr": "file:///path/to/repo",
    "uid": 1,
    "repo_name": "challenge-1"
  }'
```
