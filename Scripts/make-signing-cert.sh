#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity "Nexo Local Signing" in the login keychain.
# A stable identity keeps TCC grants (Accessibility, Screen Recording) across rebuilds; ad-hoc
# signatures change on every build and macOS forgets the permissions.
# Adapted from AltTab's scripts/codesign/generate_selfsigned_certificate.sh (GPL-3.0).
set -euo pipefail

name="Nexo Local Signing"
dir="$(cd "$(dirname "$0")" && pwd)/.signing"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  echo "Identity '$name' already present. Nothing to do."
  exit 0
fi

# Imported earlier but never trusted (e.g. the trust prompt was cancelled): re-trust instead of
# creating a duplicate identity that would make codesign ambiguous.
if security find-certificate -c "$name" >/dev/null 2>&1; then
  [[ -f "$dir/nexo.crt" ]] || { echo "'$name' exists in the keychain but is untrusted and $dir/nexo.crt is missing. Delete it in Keychain Access and re-run." >&2; exit 1; }
  security add-trusted-cert -r trustRoot -p codeSign "$dir/nexo.crt"
  security find-identity -v -p codesigning | grep "\"$name\""
  exit 0
fi

command -v bw >/dev/null || { echo "Bitwarden CLI (bw) is required to generate the p12 password." >&2; exit 1; }
export NEXO_P12_PW
NEXO_P12_PW="$(bw generate -ulns --length 32)"

# macOS Keychain only imports PKCS12 with legacy algorithms; system LibreSSL emits those by default,
# Homebrew OpenSSL 3/4 does not.
ossl=/usr/bin/openssl

umask 077
mkdir -p "$dir"
chmod 700 "$dir"
trap 'rm -f "$dir"/nexo.key "$dir"/nexo.p12 "$dir"/nexo.conf' EXIT

cat >"$dir/nexo.conf" <<EOL
[ req ]
distinguished_name = req_name
prompt = no
[ req_name ]
CN = $name
[ extensions ]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,1.3.6.1.5.5.7.3.3
1.2.840.113635.100.6.1.14=critical,DER:0500
EOL

"$ossl" genrsa -out "$dir/nexo.key" 2048
"$ossl" req -x509 -new -days 3650 -config "$dir/nexo.conf" -nodes -key "$dir/nexo.key" \
  -extensions extensions -sha256 -out "$dir/nexo.crt"

"$ossl" pkcs12 -export -inkey "$dir/nexo.key" -in "$dir/nexo.crt" -out "$dir/nexo.p12" \
  -passout env:NEXO_P12_PW

# `security import` only takes the passphrase via argv; the p12 is short-lived and deleted by the trap.
security import "$dir/nexo.p12" -P "$NEXO_P12_PW" -T /usr/bin/codesign
echo "macOS will ask for your login password to trust the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign "$dir/nexo.crt"

security find-identity -v -p codesigning | grep "\"$name\""
echo "Done. Certificate (public part) kept at $dir/nexo.crt"
