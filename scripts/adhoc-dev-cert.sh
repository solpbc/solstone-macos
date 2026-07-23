#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Local ad-hoc test builds only; never shipped; never invoked by production or CI.
# Creates an optional stable local codesign identity so login-keychain prompts do
# not recur across ad-hoc rebuilds.

set -euo pipefail

CN="${ADHOC_CERT_CN:-solstone local dev}"
LOGIN_KC="${HOME}/Library/Keychains/login.keychain-db"

usage() {
  cat >&2 <<'EOF'
usage: scripts/adhoc-dev-cert.sh [install|identity]

commands:
  install   create/import the local dev codesign identity if missing
  identity  print the identity common name if exactly one matching identity exists
EOF
}

matching_identity_hashes() {
  security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | awk -v cn="$CN" '
    /^[[:space:]]*[0-9]+\) [0-9A-Fa-f]+ "/ {
      parts_count = split($0, parts, "\"")
      if (parts_count >= 2 && parts[2] == cn) {
        line = $0
        sub(/^[[:space:]]*[0-9]+\) /, "", line)
        sub(/[[:space:]].*$/, "", line)
        print toupper(line)
      }
    }
  ' | sort -u
}

matching_cert_hashes() {
  security find-certificate -a -c "$CN" -Z "$LOGIN_KC" 2>/dev/null | awk '
    /^SHA-256 hash: / {
      print toupper($3)
    }
  ' | sort -u
}

single_line_or_empty() {
  awk 'NF { count += 1; value = $0 } END { if (count == 1) print value; else exit 1 }'
}

has_any_match() {
  local identities certs

  identities="$(matching_identity_hashes)"
  certs="$(matching_cert_hashes)"

  [ -n "$identities" ] || [ -n "$certs" ]
}

identity_hash() {
  local identities certs identity cert

  identities="$(matching_identity_hashes)"
  certs="$(matching_cert_hashes)"

  identity="$(printf '%s\n' "$identities" | single_line_or_empty)" || return 1
  cert="$(printf '%s\n' "$certs" | single_line_or_empty)" || return 1

  # find-identity proves the private key is present; find-certificate proves the
  # certificate lookup by CN is unambiguous. The hashes may differ by algorithm.
  [ -n "$identity" ] && [ -n "$cert" ]
}

print_identity() {
  identity_hash >/dev/null || exit 1
  printf '%s\n' "$CN"
}

install_identity() {
  local tmpdir p12_pass

  if identity_hash >/dev/null; then
    printf '%s\n' "$CN"
    return 0
  fi

  if has_any_match; then
    printf 'error: ambiguous existing "%s" code-signing entries in %s\n' "$CN" "$LOGIN_KC" >&2
    printf '       remove duplicate "%s" entries from login.keychain-db, then rerun this script\n' "$CN" >&2
    exit 1
  fi

  tmpdir="$(mktemp -d -t solstone-adhoc-cert)"
  trap 'rm -rf "$tmpdir"' EXIT

  cat > "$tmpdir/openssl.cnf" <<EOF
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = codesign_ext

[ dn ]
CN = ${CN}

[ codesign_ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req -new -newkey rsa:2048 -nodes -x509 -days 825 -sha256 \
    -config "$tmpdir/openssl.cnf" \
    -keyout "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem"

  p12_pass="$(openssl rand -hex 16)"
  openssl pkcs12 -export \
    -inkey "$tmpdir/key.pem" \
    -in "$tmpdir/cert.pem" \
    -name "$CN" \
    -out "$tmpdir/identity.p12" \
    -passout "pass:${p12_pass}"

  security import "$tmpdir/identity.p12" \
    -k "$LOGIN_KC" \
    -f pkcs12 \
    -P "$p12_pass" \
    -T /usr/bin/codesign

  if [ -n "${ADHOC_KEYCHAIN_PASSWORD:-}" ]; then
    security set-key-partition-list -S apple-tool:,apple: -s \
      -k "$ADHOC_KEYCHAIN_PASSWORD" "$LOGIN_KC"
  else
    security set-key-partition-list -S apple-tool:,apple: -s "$LOGIN_KC"
  fi

  print_identity
}

case "${1:-install}" in
  identity)
    print_identity
    ;;
  install)
    install_identity
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
