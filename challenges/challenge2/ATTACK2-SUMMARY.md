# Attack #2: Container Image Layer Leak - Setup Summary

## ✅ Attack Successfully Configured!

All components for Attack #2 are now in place and tested.

### What Was Created

#### 1. Vulnerable Docker Image
- **Location**: `challenges/victim-repo-sample/Dockerfile`
- **Image**: `localhost:30000/recipe-api:v1.0`
- **Vulnerability**: Single-stage build with `.git` copied and then "deleted"
- **Key Layers**:
  - Layer `e83a405bc...`: Contains `app/.git/` with full commit history
  - Layer `9a6ffeb45...`: Contains `app/.wh..git` (whiteout marker showing deletion)

#### 2. Git Repository with Secrets
- **Commits**:
  - `b4acebb` - Initial commit with `.env.production` containing:
    - Database credentials
    - API keys (Stripe, SendGrid)
    - Session secrets
    - **Registry credentials**: `ctf-admin` / `CTFRegistryPass123!`
    - **FLAG**: `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}`
  - `6f94c1f` - "Security fix" that deletes `.env.production`

#### 3. Updated Attack #1 Flag
- **Old**: `FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}`
- **New**: `FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}`
- **Secret `ctf-flag` in namespace `ctf-challenge` now includes**:
  - `flag`: Updated with registry hint
  - `registry-url`: `https://localhost:30000`
  - `registry-user`: `ctf-admin`
  - `registry-password`: `CTFRegistryPass123!`
  - `next-target`: `recipe-api:v1.0`

#### 4. Documentation
- **ATTACK2-README.md** - Overview, setup, and participant guide
- **ATTACK2-EXPLOITATION-GUIDE.md** - Detailed step-by-step exploitation
- **ATTACK2-SUMMARY.md** - This file
- **test-attack2.sh** - Automated verification script

### Attack Flow

```
Attack #1 (Tekton PWN)
         ↓
   Steal ctf-flag secret
         ↓
   Extract registry credentials
         ↓
   Login to registry @ localhost:30000
         ↓
   Discover recipe-api:v1.0
         ↓
   Pull and save image
         ↓
   Extract image layers
         ↓
   Find .git in layer e83a405bc...
         ↓
   Extract git history
         ↓
   git show b4acebb:.env.production
         ↓
   Capture FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}
         ↓
   Proceed to Attack #3: webhook_c0nf1g_1nj3ct10n
```

### Verification

Run the automated test:
```bash
cd challenges/victim-repo-sample
./test-attack2.sh
```

**Expected Output**: All 7 checks pass ✅

### Quick Manual Test

```bash
# 1. Get credentials from Attack #1
kubectl get secret ctf-flag -n ctf-challenge -o json | jq -r '.data | map_values(@base64d)'

# 2. Login to registry
podman login localhost:30000 --tls-verify=false -u ctf-admin -p CTFRegistryPass123!

# 3. Pull image
podman pull localhost:30000/recipe-api:v1.0 --tls-verify=false

# 4. Save and extract
podman save localhost:30000/recipe-api:v1.0 -o /tmp/recipe.tar
mkdir /tmp/extract && tar -xf /tmp/recipe.tar -C /tmp/extract

# 5. Find .git layer
cd /tmp/extract
for f in e83a405bc5fe*.tar; do
    tar -xf "$f"
done

# 6. Extract flag
cd app
git show b4acebb:.env.production | grep FLAG
```

### Files Modified/Created

```
challenges/victim-repo-sample/
├── .git/                              # NEW - Git repository with secret history
│   ├── objects/                       # Contains deleted .env.production
│   ├── logs/                          # Git reflog
│   ├── COMMIT_EDITMSG
│   ├── config
│   └── HEAD
├── Dockerfile                         # MODIFIED - Single-stage vulnerable build
├── go.mod                             # MODIFIED - Compatible Go version
├── main.go                            # UNCHANGED
├── internal/recipe/recipe.go          # UNCHANGED
├── ATTACK2-README.md                  # NEW - Participant guide
├── ATTACK2-EXPLOITATION-GUIDE.md      # NEW - Detailed walkthrough
├── ATTACK2-SUMMARY.md                 # NEW - This file
└── test-attack2.sh                    # NEW - Verification script

Container Registry:
├── localhost:30000/recipe-api:v1.0    # NEW - Pushed vulnerable image

Kubernetes Secrets:
└── ctf-flag (namespace: ctf-challenge)# MODIFIED - Added registry credentials
```

### Security Lessons Taught

1. **Container Layer Immutability**
   - Deleting files doesn't remove them from previous layers
   - Each Docker instruction creates an immutable layer
   - Layer analysis is a critical forensics skill

2. **Git History Permanence**
   - Deleted files remain in git history
   - `.git` directories should never be in production artifacts
   - Secret rotation is required after any exposure

3. **Supply Chain Security**
   - Build artifacts can leak sensitive information
   - `.dockerignore` is essential
   - Multi-stage builds should exclude development artifacts

4. **Detection Mechanisms**
   - Image scanning (Trivy, Grype)
   - Layer analysis tools (dive, container-diff)
   - Secret detection (git-secrets, TruffleHog)

### Real-World Analogues

- **Uber (2017)**: AWS keys in Git history within container image
- **Docker Hub (2019)**: 17% of images contained exposed secrets
- **Code42 (2021)**: Private keys in deleted-but-accessible layers
- **npm packages**: Thousands of packages with leaked `.git` directories

### Connection to Attack #3

The flag hints at: `webhook_c0nf1g_1nj3ct10n`

**Next vulnerability**: Gitea webhook manipulation
- Use registry access to modify webhook configurations
- Inject malicious webhook URLs to intercept pipeline triggers
- Manipulate CI/CD execution flows
- Potentially trigger unauthorized builds or data exfiltration

### Troubleshooting

**Image not in registry?**
```bash
cd challenges/victim-repo-sample
podman build -t localhost:30000/recipe-api:v1.0 .
podman push localhost:30000/recipe-api:v1.0 --tls-verify=false
```

**.git not in layers?**
```bash
# Verify .git exists
ls -la .git/

# Rebuild with no cache
podman build --no-cache -t localhost:30000/recipe-api:v1.0 .
podman push localhost:30000/recipe-api:v1.0 --tls-verify=false
```

**Can't find flag in git history?**
```bash
cd challenges/victim-repo-sample
git log --all --oneline
git show b4acebb:.env.production
```

### CTF Organizer Notes

**Difficulty**: Medium
**Estimated Time**: 30-60 minutes
**Prerequisites**: 
- Completed Attack #1
- Basic Docker/Podman knowledge
- Basic Git knowledge
- Familiarity with tar archives

**Hints for Stuck Participants**:
1. "Look at the Dockerfile - notice how .git is handled"
2. "Image layers are immutable - deleted files might still exist somewhere"
3. "Use `podman save` to export the image as a tar archive"
4. "Each .tar file in the extracted image represents a layer"
5. "Look for `app/.git/` in the layer tar files"
6. "Once you find .git, use standard git commands to explore history"
7. "The secrets were committed, then deleted - check the first commit"

**Solution Walkthrough**: See [ATTACK2-EXPLOITATION-GUIDE.md](./ATTACK2-EXPLOITATION-GUIDE.md)

### Success Criteria

✅ Participants successfully:
1. Obtain registry credentials from Attack #1
2. Access the container registry
3. Pull the recipe-api:v1.0 image
4. Extract and analyze image layers
5. Locate the .git directory in a previous layer
6. Explore git commit history
7. Find the .env.production file in the first commit
8. Extract the flag: `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}`
9. Understand the vulnerability and prevention measures
10. Are prepared for Attack #3

---

## Ready for Deployment! 🚀

All components are configured and tested. Participants can now begin Attack #2.

**Test Status**: ✅ PASSING (7/7 checks successful)

