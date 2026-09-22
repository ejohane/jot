#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LATTICE_NOTARY_KEY_ID:?Missing notarization key ID}"
: "${LATTICE_NOTARY_ISSUER_ID:?Missing notarization issuer ID}"
: "${LATTICE_NOTARY_PRIVATE_KEY:?Missing notarization private key}"
key_file="$(mktemp)"
trap 'rm -f "$key_file"' EXIT
chmod 600 "$key_file"
printf '%s' "$LATTICE_NOTARY_PRIVATE_KEY" > "$key_file"
ditto -c -k --keepParent dist/Jot.app dist/notarization.zip
xcrun notarytool submit dist/notarization.zip \
  --key "$key_file" --key-id "$LATTICE_NOTARY_KEY_ID" \
  --issuer "$LATTICE_NOTARY_ISSUER_ID" --wait --output-format json > dist/notarization.json
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('dist/notarization.json').read_text())
print('Notarization:', result.get('status'), 'submission:', result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this build; inspect the notarization log before retrying.')
PY
xcrun stapler staple dist/Jot.app
xcrun stapler validate dist/Jot.app
codesign --verify --deep --strict dist/Jot.app
spctl --assess --type execute --verbose=2 dist/Jot.app
# The downloadable archive must contain the stapled app, not the submitted one.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent dist/Jot.app dist/Jot.zip
(cd dist && shasum -a 256 Jot.zip > Jot.zip.sha256)
