#!/usr/bin/env bash
# Shared certificate utilities for registry setup scripts.
# Source this file; do not execute it directly.

cert_is_valid() {
    local cert="$1" key="$2"
    [ -f "$cert" ] && [ -f "$key" ] && \
    openssl x509 -checkend 86400 -noout -in "$cert" 2>/dev/null
}

cert_sans_match() {
    local cert="$1" domain="$2"
    openssl x509 -in "$cert" -noout -text 2>/dev/null \
        | grep -A1 "Subject Alternative Name" \
        | grep -qi "$domain"
}
