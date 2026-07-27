#!/usr/bin/env bash
# golang-cut-tag: compute the next semantic version for a Go module and create (and push) the tag.
#
# Why this is tag-driven rather than manifest-driven, unlike its siblings: every other ecosystem
# keeps the version in a file the cut-tag action rewrites — Cargo.toml, package.json, the .csproj,
# the pom. A Go module has no such field. `go.mod` states the module path and the language version,
# never the module's own version: for Go, the git tag IS the version, and `go get` resolves releases
# by reading tags. So there is nothing to bump and nothing to commit — this action reads the latest
# tag, computes the next one, and tags. That also makes it work unchanged on a legacy repository
# being retrofitted, which has no version file to add.
#
# Driven entirely by INPUT_* environment variables (GitHub Actions convention):
#   INPUT_VERSION_FILE   Optional version-line file holding '<prefix><major>.<minor>' (e.g. 'v1.2').
#                        When present it acts as a FLOOR the maintainer controls; when absent the
#                        latest tag alone decides. Never written to.
#   INPUT_VERSION_LEVEL  patch | minor | major (default patch).
#   INPUT_PREFIX         Tag prefix (default 'v'); inferred from the version file when it exists.
#   INPUT_PRE_RELEASE    'true' to build a pre-release tag '<version>-<epoch>'.
#   INPUT_SKIP_PUSH      'true' to skip pushing the tag (useful for testing).
set -euo pipefail

VERSION_FILE="${INPUT_VERSION_FILE:-.version-line}"
LEVEL="${INPUT_VERSION_LEVEL:-patch}"
PREFIX_OVERRIDE="${INPUT_PREFIX:-}"
PRE_RELEASE="${INPUT_PRE_RELEASE:-false}"
SKIP_PUSH="${INPUT_SKIP_PUSH:-false}"

# ---- Validate version-level ------------------------------------------------
if [[ ! "$LEVEL" =~ ^(patch|minor|major)$ ]]; then
  echo "::error title=Invalid version-level::version-level must be 'patch', 'minor', or 'major' (got '$LEVEL')."
  exit 1
fi

# ---- Read the version-line file, if there is one ---------------------------
# The floor defaults to 0.0 so a repository with no version file and no tags starts at v0.0.1 on a
# patch bump — the same place `go get` would consider the module's first release.
FMAJ=0
FMIN=0
PREFIX="${PREFIX_OVERRIDE:-v}"

if [ -f "$VERSION_FILE" ]; then
  RAW="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
  if [ -z "$RAW" ]; then
    echo "::error title=Empty version file::Version file '$VERSION_FILE' exists but is empty. Either remove it or give it '<prefix><major>.<minor>', e.g. 'v1.2'."
    exit 1
  fi

  # Prefix = leading non-digit characters (unless overridden); number = the rest.
  FILE_PREFIX="$(printf '%s' "$RAW" | sed -E 's/^([^0-9]*).*/\1/')"
  NUM="$(printf '%s' "$RAW" | sed -E 's/^[^0-9]*//')"

  if ! printf '%s' "$NUM" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
    echo "::error title=Malformed version file::Expected '<prefix><major>.<minor>' (e.g. 'v1.2'), got '$RAW'."
    exit 1
  fi

  FMAJ="$(printf '%s' "$NUM" | cut -d. -f1)"
  FMIN="$(printf '%s' "$NUM" | cut -d. -f2)"
  if [ -z "$PREFIX_OVERRIDE" ]; then
    PREFIX="$FILE_PREFIX"
  fi
  echo "Version-line floor: ${PREFIX}${FMAJ}.${FMIN}  (from $VERSION_FILE)"
else
  echo "Version-line floor: ${PREFIX}0.0  (no $VERSION_FILE — the latest tag decides)"
fi

# ---- Find the latest matching RELEASE tag ----------------------------------
# Only release tags (no pre-release suffix) with this exact prefix are considered, so a string of
# pre-release tags never advances the release line.
git fetch --tags --quiet 2>/dev/null || true
# substr(...)==p (not index) so an empty prefix matches every tag on all awk variants.
LATEST_TAG="$(git tag --sort=-version:refname | awk -v p="$PREFIX" '
  { t=$0
    if (substr(t, 1, length(p)) == p) {
      v = substr(t, length(p) + 1)
      if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print t; exit }
    } }')"

if [ -n "$LATEST_TAG" ]; then
  TV="${LATEST_TAG#"$PREFIX"}"
  TMAJ="$(printf '%s' "$TV" | cut -d. -f1)"
  TMIN="$(printf '%s' "$TV" | cut -d. -f2)"
  TPATCH="$(printf '%s' "$TV" | cut -d. -f3)"
  echo "Latest release tag: $LATEST_TAG"
else
  TMAJ=0; TMIN=0; TPATCH=0
  echo "Latest release tag: (none)"
fi

# ---- Bump from the latest tag, then clamp up to the file floor -------------
case "$LEVEL" in
  major) NMAJ=$((TMAJ + 1)); NMIN=0;             NPATCH=0 ;;
  minor) NMAJ=$TMAJ;         NMIN=$((TMIN + 1)); NPATCH=0 ;;
  patch) NMAJ=$TMAJ;         NMIN=$TMIN;         NPATCH=$((TPATCH + 1)) ;;
esac

# If the file's line leapfrogs the tag-derived bump, honor it and reset patch.
if [ "$FMAJ" -gt "$NMAJ" ] || { [ "$FMAJ" -eq "$NMAJ" ] && [ "$FMIN" -gt "$NMIN" ]; }; then
  NMAJ=$FMAJ; NMIN=$FMIN; NPATCH=0
fi

BASE_VERSION="${NMAJ}.${NMIN}.${NPATCH}"

# ---- Apply pre-release suffix if requested ---------------------------------
if [ "$PRE_RELEASE" = "true" ]; then
  TS="$(date -u +%s)"
  VERSION="${BASE_VERSION}-${TS}"
  IS_PRE_RELEASE="true"
else
  VERSION="$BASE_VERSION"
  IS_PRE_RELEASE="false"
fi

TAG="${PREFIX}${VERSION}"
echo "Next version: $VERSION"
echo "Next tag:     $TAG"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "::error title=Tag already exists::Tag '$TAG' already exists."
  exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=$VERSION"
    echo "base-version=$BASE_VERSION"
    echo "tag=$TAG"
    echo "is-pre-release=$IS_PRE_RELEASE"
  } >> "$GITHUB_OUTPUT"
fi

# ---- Ensure a tagger identity for the annotated tag ------------------------
if [ -z "$(git config user.email || true)" ]; then
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
fi

# ---- Create and push the annotated tag -------------------------------------
git tag -a "$TAG" -m "Release $TAG"
echo "Created tag: $TAG"

if [ "$SKIP_PUSH" != "true" ]; then
  git push origin "$TAG"
  echo "Pushed $TAG to origin"
else
  echo "Skipping push (skip-push=true)"
fi
