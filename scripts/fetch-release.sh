#!/usr/bin/env bash
# Download a channel build from releases.ecash.com, verify its provenance,
# and unpack it. Idempotent: DEST_DIR records the commit it holds.
set -euo pipefail

RELEASES_URL="${RELEASES_URL:-https://releases.ecash.com}"
SIGNER_WORKFLOW="${SIGNER_WORKFLOW:-ecash-com/releases/.github/workflows/publish.yml}"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") PROJECT REPO CHANNEL TARGET DEST_DIR

  PROJECT   top-level prefix on the server, e.g. L1-ecash-bitcoin
  REPO      GitHub repository the build came from, e.g. ecash-com/bitcoin
  CHANNEL   published branch, e.g. betanet
  TARGET    target triple, e.g. x86_64-unknown-linux-gnu
  DEST_DIR  where the unpacked directory ends up

Environment: RELEASES_URL (default $RELEASES_URL)
             SIGNER_WORKFLOW (default $SIGNER_WORKFLOW)
EOF
    exit 2
}

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

is_safe_path_component() {
    case "$1" in
        *[!A-Za-z0-9._-]* | '' | .*) return 1 ;;
    esac
}

require_tools() {
    for tool in curl jq unzip gh; do
        command -v "$tool" >/dev/null || die "'$tool' is required"
    done
    # Captured rather than piped into grep -q: pipefail plus grep's early
    # exit can SIGPIPE gh and fail the check on a gh that is new enough.
    local help
    help="$(gh attestation verify --help 2>/dev/null || true)"
    case "$help" in
        *--source-digest*) ;;
        *) die "gh $(gh --version | head -1) lacks the attestation flags used here; upgrade gh" ;;
    esac
}

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# Verifies that $1 was attested by SIGNER_WORKFLOW, run for REPO on CHANNEL at COMMIT.
verify_provenance() {
    gh attestation verify "$1" \
        --bundle "$TMP/provenance.jsonl" \
        --repo "$REPO" \
        --signer-workflow "$SIGNER_WORKFLOW" \
        --source-ref "refs/heads/$CHANNEL" \
        --source-digest "$COMMIT" \
        --deny-self-hosted-runners
}

[ $# -eq 5 ] || usage
PROJECT="$1" REPO="$2" CHANNEL="$3" TARGET="$4" DEST_DIR="$5"
for name in PROJECT CHANNEL TARGET; do
    is_safe_path_component "${!name}" || die "invalid $name '${!name}'"
done
case "$REPO" in */*) ;; *) die "invalid REPO '$REPO': expected owner/name" ;; esac
require_tools

CHANNEL_URL="$RELEASES_URL/$PROJECT/$CHANNEL"
ZIP_NAME="$PROJECT-$TARGET.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Only release.json is read through latest/; everything else comes from the
# immutable path it names.
curl -fsSL "$CHANNEL_URL/latest/release.json" -o "$TMP/release.json" \
    || die "could not fetch $CHANNEL_URL/latest/release.json"
COMMIT="$(jq -er '.commit' "$TMP/release.json")"
VERSION="$(jq -er '.version' "$TMP/release.json")"
RELEASE_PATH="$(jq -er '.path' "$TMP/release.json")"
EXPECTED_SHA256="$(jq -er --arg name "$ZIP_NAME" \
    '.files[] | select(.name == $name) | .sha256' "$TMP/release.json")" \
    || die "$CHANNEL@${COMMIT:0:12} publishes no $ZIP_NAME"
case "$COMMIT" in *[!0-9a-f]* | '') die "release.json: bad commit '$COMMIT'" ;; esac
case "$RELEASE_PATH" in "$PROJECT/$CHANNEL/"*) ;; *) die "release.json: path '$RELEASE_PATH' is outside $PROJECT/$CHANNEL/" ;; esac
RELEASE_URL="$RELEASES_URL/${RELEASE_PATH%/}"

if [ "$(cat "$DEST_DIR/.release-commit" 2>/dev/null || true)" = "$COMMIT" ]; then
    echo "$PROJECT $CHANNEL: cached ($VERSION @ ${COMMIT:0:12})"
    exit 0
fi

echo "Downloading $PROJECT $CHANNEL $VERSION @ ${COMMIT:0:12} ($TARGET)..."
curl -fsSL "$RELEASE_URL/provenance.jsonl" -o "$TMP/provenance.jsonl"
curl -# -fL "$RELEASE_URL/$ZIP_NAME" -o "$TMP/$ZIP_NAME"

echo "Verifying build provenance..."
# release.json is attested too; once it passes, every field read above is trusted.
verify_provenance "$TMP/release.json" || die "release.json failed provenance verification"
[ "$(sha256 "$TMP/$ZIP_NAME")" = "$EXPECTED_SHA256" ] || die "$ZIP_NAME: sha256 does not match release.json"
verify_provenance "$TMP/$ZIP_NAME" || die "$ZIP_NAME failed provenance verification"

mkdir "$TMP/unpacked"
unzip -q "$TMP/$ZIP_NAME" -d "$TMP/unpacked"
UNPACKED_DIRS=("$TMP/unpacked"/*/)
[ ${#UNPACKED_DIRS[@]} -eq 1 ] && [ -d "${UNPACKED_DIRS[0]}" ] \
    || die "$ZIP_NAME: expected exactly one top-level directory, got: $(ls "$TMP/unpacked")"

rm -rf "$DEST_DIR"
mkdir -p "$(dirname "$DEST_DIR")"
mv "${UNPACKED_DIRS[0]%/}" "$DEST_DIR"
printf '%s\n' "$COMMIT" >"$DEST_DIR/.release-commit"
echo "Installed $PROJECT $CHANNEL $VERSION @ ${COMMIT:0:12} to $DEST_DIR"
