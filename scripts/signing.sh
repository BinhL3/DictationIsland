#!/usr/bin/env bash
# Creates (once) a local, self-signed code-signing identity in its own keychain.
#
# Why: ad-hoc signatures change on every build, and macOS ties Microphone / Input Monitoring /
# Accessibility grants to the signature, so each rebuild looked like a new app. Signing with the
# same certificate every time keeps the grants.
#
# The identity lives in ~/Library/Keychains/dictationisland-signing.keychain-db (not your login
# keychain). Its password is generated and stored in ~/.config/dictationisland/ (mode 600).
# It's only trusted by this Mac; for distribution to other Macs you'd use a Developer ID.
#
# Prints the identity's SHA-1 for `codesign --sign`. Remove everything with: scripts/signing.sh --remove
set -euo pipefail

NAME="DictationIsland Local Signing"
KEYCHAIN="$HOME/Library/Keychains/dictationisland-signing.keychain-db"
CONFIG_DIR="$HOME/.config/dictationisland"
PASSFILE="$CONFIG_DIR/signing-keychain-password"

if [[ "${1:-}" == "--remove" ]]; then
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -f "$PASSFILE"
  echo "Removed $KEYCHAIN"
  exit 0
fi

identity_hash() {
  security find-certificate -c "$NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}'
}

if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
  HASH="$(identity_hash)"
  if [[ -n "$HASH" ]]; then
    echo "$HASH"
    exit 0
  fi
fi

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
umask 077
PASS="$(/usr/bin/openssl rand -hex 24)"
printf '%s' "$PASS" >"$PASSFILE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:"$PASS" -name "$NAME" >/dev/null 2>&1

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

identity_hash
