#!/usr/bin/env bash
# The local code-signing identity every build of this app is signed with, and
# the one place that decides which identity that is.
#
#   Scripts/local-signing-identity.sh setup
#       One time per machine, interactive. Creates the "Grand Line Local CA"
#       certificate if there is none, then issues a "Grand Line Code Signing"
#       certificate from it if there is no valid one. Never creates a second
#       CA. Run it again whenever the build says the signing certificate is
#       missing or invalid - it only reissues the leaf.
#
#   Scripts/local-signing-identity.sh sign <bundle> <identifier> [codesign args...]
#       Sign <bundle> with the best local identity and verify the result.
#       Exits 4 when there is no local identity at all, so the caller decides
#       what an unsigned build means for it.
#
#   Scripts/local-signing-identity.sh requirement <identifier>
#       Print the designated requirement a CA-anchored build of <identifier>
#       carries, or nothing when the CA does not exist yet.
#
#   Scripts/local-signing-identity.sh status
#       Say which identity a build would use, and what that means for grants.
#
#   Scripts/local-signing-identity.sh certificates <dir>
#       Write a fresh CA and a leaf issued by it to <dir> and touch no
#       keychain. This is the recipe `setup` uses, separated so a test can
#       check it.
#
# Why a CA (fm/grand-line-stable-signing-identity). macOS files every privacy
# grant (Accessibility, Screen Recording, Input Monitoring) and every Keychain
# ACL against the app's designated requirement. codesign's default requirement
# for a self-signed certificate is
#
#   identifier "com.manjesh.grandline.native" and certificate leaf = H"<sha1>"
#
# which pins the certificate itself. Recreating it on 2026-11-15 revoked every
# grant at once, while System Settings kept showing them switched on (the
# incident is in Scripts/check-signing-identity.sh). This script signs with a
# leaf issued by a local CA instead, and states the requirement explicitly:
#
#   identifier "com.manjesh.grandline.native" and certificate root = H"<CA sha1>"
#
# A leaf reissued by the same CA satisfies that, so the leaf can be recreated,
# renewed or fixed without touching a grant. A certificate with the same names
# from any other CA does not, because the root hash is the CA's own. Measured
# with throwaway bundles: the old requirement fails after the leaf is
# recreated, the CA-anchored one holds, and an impostor CA fails it.
#
# Two things this does not change, on purpose:
#
#   - The CA itself is the identity now. Recreating *it* is the old failure
#     again, which is why `setup` refuses to make a second one and
#     check-signing-identity.sh still warns when a build stops satisfying the
#     requirement of the copy it replaces.
#   - No requirement that pins no key at all. `certificate leaf[subject.CN]`
#     or a bare `identifier` would survive anything, and would hand the app's
#     Accessibility grant to any binary that claims the same names.
#
# The CA's private key is only needed to issue a leaf, so it lives in the
# login keychain as a generic password that no application may read without
# asking (`-T ""`). `setup` reads it only when it has to reissue the leaf, and
# macOS asks first.
#
# FM_SIGNING_KEYCHAIN points every lookup and import at one keychain file
# instead of the user's search list. The tests use it with a throwaway
# keychain; nothing else should set it.

set -euo pipefail

CA_NAME="Grand Line Local CA"
LEAF_NAME="Grand Line Code Signing"
ORGANIZATION="Grand Line Local"
CA_KEY_SERVICE="Grand Line Local CA private key"
# The self-signed identities earlier builds used, newest first. Still used
# when the CA has not been set up, so an existing machine keeps signing the
# way it did until the captain runs `setup`.
LEGACY_NAMES=("Grand Line Local Dev" "Firstmate Cockpit Local Dev")
CA_DAYS=10950   # 30 years: outlives the machine, and it must never change.
LEAF_DAYS=3650  # Reissuing the leaf costs nothing, so it may expire.
# `security -i` reads one line per command and silently truncates a long one.
# Measured: a 3164-character value survives and a 3312-character one does not.
# A 3072-bit RSA key in DER is about 2400 characters of base64.
MAX_STORED_KEY_CHARS=3000

KEYCHAIN_ARGS=()
if [ -n "${FM_SIGNING_KEYCHAIN:-}" ]; then
  KEYCHAIN_ARGS=("$FM_SIGNING_KEYCHAIN")
fi
IMPORT_KEYCHAIN="${FM_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

usage() {
  echo "usage: $0 setup" >&2
  echo "       $0 sign <bundle> <identifier> [codesign args...]" >&2
  echo "       $0 requirement <identifier>" >&2
  echo "       $0 status" >&2
  echo "       $0 certificates <dir>" >&2
  exit 2
}

# The SHA-1 of the first *valid* code-signing identity named exactly $1.
# `-v` leaves out anything expired, untrusted or unusable for code signing.
valid_identity() {
  security find-identity -v -p codesigning ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null \
    | awk -v name="\"$1\"" '$1 ~ /^[0-9]+\)$/ && substr($0, index($0, "\"")) == name { print $2; exit }'
}

# The SHA-1 of every certificate labelled exactly $1, one per line. `-c` is a
# substring match, so the label is compared again here. The search list names
# System.keychain twice, hence the `sort -u`.
certificate_hashes() {
  security find-certificate -a -c "$1" -Z ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null \
    | awk -v want="\"labl\"<blob>=\"$1\"" '
        /^SHA-1 hash: / { hash = $3 }
        { line = $0; sub(/^[ \t]+/, "", line) }
        line == want { print tolower(hash) }' \
    | sort -u
}

# The CA's SHA-1, or nothing when there is no CA. Two CAs with the same name
# are refused rather than guessed between: one of them is not ours.
ca_hash() {
  local hashes count
  hashes="$(certificate_hashes "$CA_NAME")"
  count="$(printf '%s' "$hashes" | grep -c . || true)"
  if [ "$count" -gt 1 ]; then
    {
      echo "error: more than one certificate is named \"$CA_NAME\":"
      printf '%s\n' "$hashes" | sed 's/^/  /'
      echo "Only one of them signed this app's earlier builds. Remove the other"
      echo "with: security delete-certificate -Z <sha1>"
    } >&2
    return 1
  fi
  printf '%s' "$hashes"
}

requirement_for() {
  local hash
  hash="$(ca_hash)" || return 1
  [ -n "$hash" ] || return 0
  printf 'identifier "%s" and certificate root = H"%s"\n' "$1" "$hash"
}

# PEM of the certificate whose SHA-1 is $2, among those labelled $1.
certificate_pem() {
  security find-certificate -a -c "$1" -Z -p ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null \
    | awk -v want="$(printf '%s' "$2" | tr 'a-f' 'A-F')" '
        /^SHA-1 hash: / { take = ($3 == want); next }
        take && /BEGIN CERTIFICATE/ { printing = 1 }
        printing { print }
        printing && /END CERTIFICATE/ { exit }'
}

openssl_has_pkcs12_legacy() {
  # OpenSSL 3.x encrypts a .p12 in a way macOS's importer cannot read unless
  # told `-legacy`. LibreSSL, which /usr/bin/openssl is, has no such flag and
  # needs none.
  openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'
}

make_ca() { # dir
  openssl req -x509 -newkey rsa:3072 -nodes -days "$CA_DAYS" \
    -keyout "$1/ca.key" -out "$1/ca.crt" \
    -subj "/O=$ORGANIZATION/CN=$CA_NAME" \
    -addext "basicConstraints=critical,CA:true,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" 2>/dev/null
}

make_leaf() { # dir (holding ca.key and ca.crt)
  # All three extensions are needed: without basicConstraints OpenSSL 3.x
  # marks the certificate as a CA, and without keyUsage macOS rejects it as
  # "Invalid Key Usage for policy". The Organization matches the CA's, which
  # is also what makes codesign's own default requirement anchor on the CA.
  printf '%s\n' \
    "basicConstraints=critical,CA:false" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=critical,codeSigning" \
    "subjectKeyIdentifier=hash" \
    "authorityKeyIdentifier=keyid" > "$1/leaf.ext"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$1/leaf.key" -out "$1/leaf.csr" \
    -subj "/O=$ORGANIZATION/CN=$LEAF_NAME" 2>/dev/null
  openssl x509 -req -in "$1/leaf.csr" -CA "$1/ca.crt" -CAkey "$1/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$LEAF_DAYS" \
    -extfile "$1/leaf.ext" -out "$1/leaf.crt" 2>/dev/null
  rm -f "$1/leaf.csr" "$1/leaf.ext"
}

sha1_of() {
  openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
}

sign_bundle() { # bundle identifier [codesign args...]
  local bundle="$1" identifier="$2" leaf requirement name
  shift 2
  leaf="$(valid_identity "$LEAF_NAME")"
  requirement="$(requirement_for "$identifier")" || return 1
  if [ -n "$leaf" ] && [ -n "$requirement" ]; then
    echo "Signing with \"$LEAF_NAME\", anchored on \"$CA_NAME\"…"
    codesign --force --sign "$leaf" --identifier "$identifier" \
      -r "=designated => $requirement" "$@" "$bundle"
    # A plain `codesign --verify` does not check the designated requirement
    # (measured: a bundle whose explicit requirement it fails still passes),
    # so test it explicitly. This is what fails if the CA certificate was not
    # embedded in the signature, which would leave the leaf as the root.
    if ! codesign --verify -R "=$requirement" "$bundle" 2>/dev/null; then
      echo "error: $bundle does not satisfy its own requirement:" >&2
      echo "  $requirement" >&2
      echo "  Its signature does not chain to \"$CA_NAME\". Run" >&2
      echo "  Scripts/local-signing-identity.sh status to see what is wrong." >&2
      return 1
    fi
    return 0
  fi

  for name in "${LEGACY_NAMES[@]}"; do
    leaf="$(valid_identity "$name")"
    [ -n "$leaf" ] || continue
    echo "Signing with the self-signed identity \"$name\"…"
    codesign --force --sign "$leaf" --identifier "$identifier" "$@" "$bundle"
    echo "Note: \"$name\" is a self-signed certificate, so macOS pins every"
    echo "      privacy grant to that exact certificate and recreating it revokes"
    echo "      them all. Run Scripts/local-signing-identity.sh setup once to move"
    echo "      to an identity whose certificate can be renewed safely."
    return 0
  done

  if [ -n "$requirement" ]; then
    echo "⚠️  \"$CA_NAME\" exists but there is no valid \"$LEAF_NAME\" certificate."
    echo "    Run Scripts/local-signing-identity.sh setup to reissue it. The"
    echo "    new certificate keeps every privacy grant."
  fi
  return 4
}

status() {
  local ca leaf name
  ca="$(ca_hash)" || return 1
  leaf="$(valid_identity "$LEAF_NAME")"
  if [ -n "$ca" ] && [ -n "$leaf" ]; then
    echo "Builds are signed with \"$LEAF_NAME\" ($leaf),"
    echo "issued by \"$CA_NAME\" ($ca). Their requirement is"
    echo "  $(requirement_for com.manjesh.grandline.native)"
    echo "so reissuing the leaf with \`setup\` keeps every privacy grant."
    return 0
  fi
  if [ -n "$ca" ]; then
    echo "\"$CA_NAME\" ($ca) exists, but there is no valid \"$LEAF_NAME\"."
    security find-identity -p codesigning ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null \
      | grep -F "\"$LEAF_NAME\"" | sed 's/^/  /' || true
    echo "Run \`setup\` to reissue it."
  else
    echo "\"$CA_NAME\" has not been set up on this machine."
  fi
  for name in "${LEGACY_NAMES[@]}"; do
    leaf="$(valid_identity "$name")"
    if [ -n "$leaf" ]; then
      echo "Builds fall back to the self-signed \"$name\" ($leaf), whose"
      echo "requirement pins that certificate."
      return 0
    fi
  done
  echo "Builds are unsigned."
}

setup() {
  local ca leaf legacy key_b64
  command -v openssl >/dev/null || { echo "error: openssl is required" >&2; return 1; }
  ca="$(ca_hash)" || return 1
  leaf="$(valid_identity "$LEAF_NAME")"
  if [ -n "$ca" ] && [ -n "$leaf" ]; then
    echo "Nothing to do."
    status
    return 0
  fi

  umask 077
  work="$(mktemp -d)"
  trap 'rm -rf "${work:-}"' EXIT

  if [ -z "$ca" ]; then
    if security find-generic-password -s "$CA_KEY_SERVICE" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} >/dev/null 2>&1; then
      echo "error: a \"$CA_KEY_SERVICE\" keychain item exists but its certificate does not." >&2
      echo "Delete it before creating a new CA:" >&2
      echo "  security delete-generic-password -s \"$CA_KEY_SERVICE\"" >&2
      return 1
    fi
    echo "Creating \"$CA_NAME\". This is the identity macOS will file this"
    echo "app's privacy grants under, so it is created once and kept."
    make_ca "$work"
    openssl pkey -in "$work/ca.key" -outform DER -out "$work/ca.der"
    key_b64="$(base64 < "$work/ca.der" | tr -d '\n')"
    # An empty value would let `-w` swallow the keychain path that follows it.
    if [ -z "$key_b64" ] || [ "${#key_b64}" -gt "$MAX_STORED_KEY_CHARS" ]; then
      echo "error: the CA key is ${#key_b64} characters, which cannot be stored safely." >&2
      return 1
    fi
    # Through `security -i` so the key travels on a pipe rather than in argv,
    # where `ps` would show it (GL-15). `-T ""` trusts no application, so any
    # later read asks first.
    printf 'add-generic-password -a "%s" -s "%s" -l "%s" -j "%s" -T "" -w %s "%s"\n' \
      "$CA_NAME" "$CA_KEY_SERVICE" "$CA_KEY_SERVICE" \
      "Issues the Grand Line Code Signing certificate. Created by native/Scripts/local-signing-identity.sh." \
      "$key_b64" "$IMPORT_KEYCHAIN" | security -i
    unset key_b64
    # Reading the attributes back asks nothing. Reading the value would.
    if ! security find-generic-password -s "$CA_KEY_SERVICE" "$IMPORT_KEYCHAIN" >/dev/null 2>&1; then
      echo "error: storing \"$CA_KEY_SERVICE\" in the keychain failed." >&2
      return 1
    fi
    security import "$work/ca.crt" -k "$IMPORT_KEYCHAIN" >/dev/null
    echo "Trusting \"$CA_NAME\" for code signing. macOS asks for your password."
    # `-r trustRoot`, not `-r trustAsRoot`: the latter fails with a parameter
    # error on this certificate shape. Trust is what makes the leaf a valid
    # code-signing identity. Nothing evaluates it after signing: tccd only
    # compares the CA's hash.
    security add-trusted-cert -d -r trustRoot -p codeSign -k "$IMPORT_KEYCHAIN" "$work/ca.crt"
    ca="$(sha1_of "$work/ca.crt")"
  else
    echo "Reissuing \"$LEAF_NAME\" from the existing \"$CA_NAME\" ($ca)."
    echo "macOS asks before this reads the CA's private key."
    certificate_pem "$CA_NAME" "$ca" > "$work/ca.crt"
    if ! security find-generic-password -s "$CA_KEY_SERVICE" -w ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null \
        | base64 -d > "$work/ca.der" || [ ! -s "$work/ca.der" ]; then
      echo "error: could not read \"$CA_KEY_SERVICE\" from the keychain, so no" >&2
      echo "certificate can be issued under \"$CA_NAME\". Making a new CA would" >&2
      echo "revoke every privacy grant again, so this script will not do it" >&2
      echo "for you. See native/README.md's \"Local signing setup\"." >&2
      return 1
    fi
    openssl pkey -inform DER -in "$work/ca.der" -out "$work/ca.key"
    if [ "$(openssl pkey -in "$work/ca.key" -pubout)" != "$(openssl x509 -in "$work/ca.crt" -noout -pubkey)" ]; then
      echo "error: the stored CA key does not belong to \"$CA_NAME\" ($ca)." >&2
      return 1
    fi
  fi

  make_leaf "$work"
  local password p12_flags=()
  password="$(openssl rand -hex 16)"
  if openssl_has_pkcs12_legacy; then
    p12_flags=(-legacy)
  fi
  openssl pkcs12 -export ${p12_flags[@]+"${p12_flags[@]}"} -inkey "$work/leaf.key" -in "$work/leaf.crt" \
    -name "$LEAF_NAME" -out "$work/leaf.p12" -passout "pass:$password"
  # `-T /usr/bin/codesign` lets codesign use the key without asking on every
  # build, the same access the self-signed identity had.
  security import "$work/leaf.p12" -k "$IMPORT_KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null

  leaf="$(valid_identity "$LEAF_NAME")"
  if [ -z "$leaf" ]; then
    echo "error: \"$LEAF_NAME\" was imported but macOS does not list it as a valid" >&2
    echo "code-signing identity. Run: security find-identity -p codesigning" >&2
    return 1
  fi

  # End to end, with Apple's codesign: sign a scratch bundle exactly the way a
  # build will, which also proves the CA lands in the signature.
  mkdir -p "$work/Check.app/Contents/MacOS"
  cp /usr/bin/true "$work/Check.app/Contents/MacOS/Check"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Check</string>' \
    '<key>CFBundleIdentifier</key><string>com.manjesh.grandline.signing-check</string></dict></plist>' \
    > "$work/Check.app/Contents/Info.plist"
  if ! sign_bundle "$work/Check.app" com.manjesh.grandline.signing-check >/dev/null; then
    echo "error: a scratch bundle signed with \"$LEAF_NAME\" did not verify." >&2
    return 1
  fi

  echo ""
  echo "✓ \"$LEAF_NAME\" ($leaf), issued by \"$CA_NAME\" ($ca)."
  for legacy in "${LEGACY_NAMES[@]}"; do
    if [ -n "$(valid_identity "$legacy")" ]; then
      echo ""
      echo "The next build_native_app.sh moves the app off \"$legacy\" and prints"
      echo "the one-time privacy-grant repair. After that, this certificate can be"
      echo "reissued with \`setup\` without macOS forgetting a grant."
      echo "Keep \"$legacy\" until that build is installed, then remove it with:"
      echo "  security delete-identity -c \"$legacy\""
      break
    fi
  done
}

[ $# -ge 1 ] || usage
case "$1" in
  setup)
    [ $# -eq 1 ] || usage
    setup
    ;;
  sign)
    [ $# -ge 3 ] || usage
    shift
    sign_bundle "$@"
    ;;
  requirement)
    [ $# -eq 2 ] || usage
    requirement_for "$2"
    ;;
  status)
    [ $# -eq 1 ] || usage
    status
    ;;
  certificates)
    [ $# -eq 2 ] || usage
    mkdir -p "$2"
    umask 077
    make_ca "$2"
    make_leaf "$2"
    ;;
  *)
    usage
    ;;
esac
