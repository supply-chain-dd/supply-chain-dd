#!/usr/bin/env bash
# Domain names and ports for local service access via Gateway API.
# Source this file in setup and demo scripts.
#
# Two port variables per cluster:
#   GATEWAY_HTTP_PORT  — Envoy Gateway HTTP listener (ci-cluster)
#   GATEWAY_HTTPS_PORT — Envoy Gateway TLS passthrough listener (ci-cluster)
#   GATEWAY_PROD_HTTP_PORT  — same for production-cluster
#   GATEWAY_PROD_HTTPS_PORT — same for production-cluster
#
# Composite *_HOST variables include the port and are ready to use
# in podman push/pull, cosign, git clone, curl, etc.

# --- Gateway ports -----------------------------------------------------------
export GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-30080}"
export GATEWAY_HTTPS_PORT="${GATEWAY_HTTPS_PORT:-30443}"
export GATEWAY_PROD_HTTP_PORT="${GATEWAY_PROD_HTTP_PORT:-31080}"
export GATEWAY_PROD_HTTPS_PORT="${GATEWAY_PROD_HTTPS_PORT:-31443}"

# --- CI cluster domain names -------------------------------------------------
export REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-registry.sc.local}"
export GITEA_DOMAIN="${GITEA_DOMAIN:-gitea.sc.local}"
export DASHBOARD_DOMAIN="${DASHBOARD_DOMAIN:-dashboard.sc.local}"
export REKOR_DOMAIN="${REKOR_DOMAIN:-rekor.sc.local}"
export FULCIO_DOMAIN="${FULCIO_DOMAIN:-fulcio.sc.local}"
export TUF_DOMAIN="${TUF_DOMAIN:-tuf.sc.local}"

# --- Production cluster domain names -----------------------------------------
export ARGOCD_DOMAIN="${ARGOCD_DOMAIN:-argocd.sc.local}"
export GITEA_PROD_DOMAIN="${GITEA_PROD_DOMAIN:-gitea-prod.sc.local}"
export REGISTRY_PROD_DOMAIN="${REGISTRY_PROD_DOMAIN:-registry-prod.sc.local}"
export APP_DOMAIN="${APP_DOMAIN:-app.sc.local}"

# --- CI cluster host:port (for podman, cosign, curl, git clone) --------------
export REGISTRY_HOST="${REGISTRY_DOMAIN}:${GATEWAY_HTTPS_PORT}"
export GITEA_HOST="${GITEA_DOMAIN}:${GATEWAY_HTTP_PORT}"
export DASHBOARD_HOST="${DASHBOARD_DOMAIN}:${GATEWAY_HTTP_PORT}"
export REKOR_HOST="${REKOR_DOMAIN}:${GATEWAY_HTTP_PORT}"
export FULCIO_HOST="${FULCIO_DOMAIN}:${GATEWAY_HTTP_PORT}"
export TUF_HOST="${TUF_DOMAIN}:${GATEWAY_HTTP_PORT}"

# --- Production cluster host:port --------------------------------------------
export ARGOCD_HOST="${ARGOCD_DOMAIN}:${GATEWAY_PROD_HTTPS_PORT}"
export GITEA_PROD_HOST="${GITEA_PROD_DOMAIN}:${GATEWAY_PROD_HTTP_PORT}"
export REGISTRY_PROD_HOST="${REGISTRY_PROD_DOMAIN}:${GATEWAY_PROD_HTTPS_PORT}"
export APP_HOST="${APP_DOMAIN}:${GATEWAY_PROD_HTTP_PORT}"

# --- SSH ports (NodePort — can't go through HTTP gateway) --------------------
export GITEA_SSH_PORT="${GITEA_SSH_PORT:-30003}"
export GITEA_PROD_SSH_PORT="${GITEA_PROD_SSH_PORT:-30005}"
