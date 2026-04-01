# Victim Repository Sample - Recipe API

This is a sample repository used for **CTF Challenge #2** (Container Image Layer Leak).

## About This Repository

This directory contains:
- A simple Go REST API for managing recipes
- A **vulnerable Dockerfile** that leaks git history
- A **_git directory** (renamed from `.git` to allow version control)

## Git History (_git)

The `_git` directory contains git history with:
- **Commit 1 (b4acebb)**: Includes `.env.production` with secrets:
  - Database credentials
  - API keys (Stripe, SendGrid)
  - Registry credentials
  - **FLAG**: `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}`
- **Commit 2 (6f94c1f)**: Attempts to delete `.env.production` (but it remains in history!)

During the build process, the Dockerfile copies this git history into the container image layers.

## Why _git Instead of .git?

Git repositories cannot contain nested `.git` directories. To version control the victim repository's git history (which contains the secrets needed for the CTF), we rename it to `_git`. 

The Makefile automatically restores it to `.git` during the build process in a temporary location.

## Setup for Challenge 2

The Makefile handles everything automatically:

```bash
# Complete setup: builds image with _git restored to .git
make setup-challenge2

# Or step by step:
make build-recipe-api    # Copies to /tmp, restores _git → .git, builds
make push-recipe-api     # Pushes to registry
make verify-challenge2   # Runs automated tests
```

## The Vulnerability

The Dockerfile contains this common mistake:

```dockerfile
COPY . .              # Copies everything INCLUDING .git
RUN rm -rf .git       # Attempts to delete .git
```

**Problem**: Docker layers are immutable. The `rm -rf .git` command only adds a deletion marker in a **new layer**. The actual `.git` content remains accessible in the **previous layer**!

Attackers can:
1. Pull the image
2. Extract the layer tar files
3. Find the layer containing `.git`
4. Extract the git history
5. Retrieve deleted secrets from git commits

## Manual Build (for testing)

If you want to build manually:

```bash
# 1. Create a temporary build directory
mkdir -p /tmp/recipe-api-build
cp -r /home/skhoury/go/src/github.com/sherine-k/supply-chain-dd/tekton/challenges/victim-repo-sample /tmp/recipe-api-build/src
cd /tmp/recipe-api-build/src

# 2. Restore git history
mv _git .git

# 3. Verify git history
git log --oneline

# 4. Build the image
podman build -t localhost:30000/recipe-api:v1.0 .

# 5. Push to registry
podman login localhost:30000 --tls-verify=false -u ctf-admin -p CTFRegistryPass123!
podman push localhost:30000/recipe-api:v1.0 --tls-verify=false
```

## Files

- `main.go` - Recipe API server (REST endpoints)
- `internal/recipe/recipe.go` - Recipe business logic
- `Dockerfile` - **VULNERABLE** - Leaks git history in image layers
- `_git/` - Git repository with secret history (**committed to version control!**)
- `go.mod` - Go module definition
- `.gitignore` - Ignores `.git` but **allows** `_git`

## Flag Location

The flag is hidden in the first git commit in `.env.production`:

```bash
# After extracting image layers:
cd /path/to/extracted/layer/with/.git
git show b4acebb:.env.production
# Look for: FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}
```

## API Endpoints

See [README-API.md](./README-API.md) for API documentation.

## For CTF Participants

1. Complete Challenge #1 to get registry credentials
2. Use those credentials to access `https://localhost:30000`
3. Pull `recipe-api:v1.0`
4. Extract image layers
5. Find `.git` directory in one of the layers
6. Explore git history for the flag

**Detailed walkthrough**: See `../challenge2/ATTACK2-EXPLOITATION-GUIDE.md`
