#!/usr/bin/env bash
# Creates a local self-signed code-signing certificate "PalMeet Development" in your login keychain.
# Signing with a stable identity keeps macOS privacy permissions (Screen Recording, Microphone, System Audio)
# across rebuilds. Then: PALMEET_SIGN_IDENTITY="PalMeet Development" scripts/build-app.sh
set -euo pipefail
NAME="PalMeet Development"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:palmeet -name "$NAME"
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P palmeet -T /usr/bin/codesign
# Trusting the certificate is optional: codesign works with an untrusted self-signed identity, and macOS
# privacy permissions key on the certificate itself. (Trust changes may require an admin prompt.)
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem" 2>/dev/null \
  || echo "Note: certificate not marked as trusted (not needed for local builds)."
echo "Created \"$NAME\". Verify with: security find-identity -p codesigning"
