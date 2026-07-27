#!/usr/bin/env bats
#
# The behavior that makes this action different from its siblings is that a Go module has no
# version field to bump: the tag is the version. So the cases that matter most are the ones with
# NO version file at all — a legacy repository being retrofitted has none, and must still tag.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/cut-tag.sh"

load "helpers/repo.sh"

setup() {
  WORK="$(mktemp -d)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Never push in tests; there is no remote.
  export INPUT_SKIP_PUSH="true"
  export INPUT_VERSION_LEVEL="patch"
  export INPUT_PREFIX=""
  export INPUT_PRE_RELEASE="false"
  export INPUT_VERSION_FILE=".version-line"
}

teardown() {
  rm -rf "$WORK"
  rm -f "$GITHUB_OUTPUT"
}

# Run the script in a repo that has NO version file. Args are tags.
run_cut_untracked() {
  make_repo "$WORK" "$@"
  ( cd "$WORK" && bash "$SCRIPT" )
}

# Run the script in a repo WITH a version file. Usage: run_cut <contents> [<tag> ...]
run_cut() {
  local vfile="$1"; shift
  make_repo "$WORK" "$@"
  write_version_file "$WORK" "$vfile"
  ( cd "$WORK" && bash "$SCRIPT" )
}

tag_out()  { output_value "$GITHUB_OUTPUT" tag; }
ver_out()  { output_value "$GITHUB_OUTPUT" version; }
base_out() { output_value "$GITHUB_OUTPUT" base-version; }
prerelease_out() { output_value "$GITHUB_OUTPUT" is-pre-release; }

# ---------------------------------------------------------------------------
# No version file — the Go case, and the retrofit case
# ---------------------------------------------------------------------------

@test "no version file and no tags starts the line at v0.0.1" {
  run_cut_untracked
  [ "$(tag_out)" = "v0.0.1" ]
}

@test "no version file bumps the patch of the latest tag" {
  run_cut_untracked v0.3.7
  [ "$(tag_out)" = "v0.3.8" ]
}

@test "no version file, minor bump" {
  export INPUT_VERSION_LEVEL="minor"
  run_cut_untracked v1.4.9
  [ "$(tag_out)" = "v1.5.0" ]
}

@test "no version file, major bump" {
  export INPUT_VERSION_LEVEL="major"
  run_cut_untracked v1.4.9
  [ "$(tag_out)" = "v2.0.0" ]
}

@test "an empty version file is an error, not a silent floor of zero" {
  make_repo "$WORK" v1.0.0
  write_version_file "$WORK" ""
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Empty version file"* ]]
}

# ---------------------------------------------------------------------------
# Version file present — it is a floor
# ---------------------------------------------------------------------------

@test "patch bump on the current line" {
  run_cut "v1.2" v1.0.0 v1.2.3 v1.2.4
  [ "$(tag_out)" = "v1.2.5" ]
  [ "$(prerelease_out)" = "false" ]
}

@test "the version file leapfrogs the latest tag and resets the patch" {
  run_cut "v2.0" v1.9.9
  [ "$(tag_out)" = "v2.0.0" ]
}

@test "a version file behind the latest tag does not drag the version backwards" {
  run_cut "v1.0" v3.4.5
  [ "$(tag_out)" = "v3.4.6" ]
}

@test "a three-part version file is accepted, using only major.minor as the floor" {
  run_cut "v1.5.9" v1.5.2
  [ "$(tag_out)" = "v1.5.3" ]
}

@test "a malformed version file is an error" {
  make_repo "$WORK" v1.0.0
  write_version_file "$WORK" "not-a-version"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Malformed version file"* ]]
}

# ---------------------------------------------------------------------------
# Prefixes
# ---------------------------------------------------------------------------

@test "the prefix is inferred from the version file" {
  run_cut "release-1.2" release-1.2.3
  [ "$(tag_out)" = "release-1.2.4" ]
}

@test "an explicit prefix overrides the version file's" {
  export INPUT_PREFIX="v"
  run_cut "release-1.2" v1.2.3 release-9.9.9
  [ "$(tag_out)" = "v1.2.4" ]
}

@test "tags with a different prefix are ignored when computing the latest" {
  run_cut_untracked other-5.0.0 v1.0.0
  [ "$(tag_out)" = "v1.0.1" ]
}

# ---------------------------------------------------------------------------
# Pre-releases
# ---------------------------------------------------------------------------

@test "a pre-release tag carries an epoch suffix and reports base-version" {
  export INPUT_PRE_RELEASE="true"
  run_cut_untracked v1.2.3
  [ "$(base_out)" = "1.2.4" ]
  [ "$(prerelease_out)" = "true" ]
  [[ "$(ver_out)" =~ ^1\.2\.4-[0-9]+$ ]]
  [[ "$(tag_out)" =~ ^v1\.2\.4-[0-9]+$ ]]
}

@test "pre-release tags never advance the release line" {
  run_cut_untracked v1.2.3 v1.2.4-1782043845
  [ "$(tag_out)" = "v1.2.4" ]
}

# ---------------------------------------------------------------------------
# Tagging behavior
# ---------------------------------------------------------------------------

@test "the tag is actually created in the repo" {
  run_cut_untracked v1.0.0
  run tags_in "$WORK"
  [[ "$output" == *"v1.0.1"* ]]
}

@test "the tag is annotated, so it carries a message and a tagger" {
  run_cut_untracked v1.0.0
  run git -C "$WORK" cat-file -t v1.0.1
  [ "$output" = "tag" ]
}

@test "no commit is created — a Go module has no version file to rewrite" {
  make_repo "$WORK" v1.0.0
  BEFORE="$(git -C "$WORK" rev-parse HEAD)"
  ( cd "$WORK" && bash "$SCRIPT" )
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$BEFORE" ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

# Cutting twice advances the line rather than colliding — the second run reads the tag the first
# one created. (The script's "tag already exists" guard is therefore not reachable this way: it
# exists for the concurrent case, where a sibling run pushes the computed tag between this run's
# fetch and its tag. That race needs two workers to reproduce, so it is not asserted here.)
@test "cutting twice advances the line instead of recreating a tag" {
  make_repo "$WORK" v1.0.0
  ( cd "$WORK" && bash "$SCRIPT" )
  ( cd "$WORK" && bash "$SCRIPT" )
  run tags_in "$WORK"
  [[ "$output" == *"v1.0.1"* ]]
  [[ "$output" == *"v1.0.2"* ]]
}

@test "the computed tag never overwrites an existing one" {
  make_repo "$WORK" v1.0.0
  ( cd "$WORK" && bash "$SCRIPT" )
  # v1.0.1 now exists and is annotated; cutting again must not rewrite it.
  BEFORE="$(git -C "$WORK" rev-parse v1.0.1)"
  ( cd "$WORK" && bash "$SCRIPT" )
  [ "$(git -C "$WORK" rev-parse v1.0.1)" = "$BEFORE" ]
}

@test "an invalid version-level is an error" {
  export INPUT_VERSION_LEVEL="huge"
  make_repo "$WORK" v1.0.0
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid version-level"* ]]
}
