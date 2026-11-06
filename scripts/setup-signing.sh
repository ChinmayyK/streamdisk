#!/bin/zsh
# Creates a self-signed code-signing identity in the login keychain.
# Builds signed with it keep the same identity, so macOS remembers "Always Allow" for the
# Keychain item holding the Google token instead of asking after every rebuild.
# No Apple developer account is involved; the certificate never leaves this Mac.
set -euo pipefail

NAME="StreamDisk Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$NAME" -out "$work/id.p12" -passout "pass:$pass"
security import "$work/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign
echo "Created \"$NAME\"."
