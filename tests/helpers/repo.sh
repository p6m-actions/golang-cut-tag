#!/usr/bin/env bash
# Test helpers: build a throwaway git repo with a set of tags, and optionally a version file.
set -euo pipefail

# make_repo <dir> <tag> [<tag> ...]
# Initializes a git repo at <dir> with one commit and the given tags.
make_repo() {
  local dir="$1"; shift
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  git -C "$dir" commit -q --allow-empty -m init
  local t
  for t in "$@"; do
    git -C "$dir" tag "$t"
  done
}

# write_version_file <dir> <contents>
write_version_file() {
  printf '%s\n' "$2" > "$1/.version-line"
}

# output_value <github_output_file> <key>
# Reads 'key=value' from a GITHUB_OUTPUT file.
output_value() {
  sed -n "s/^$2=//p" "$1"
}

# tags_in <dir> — every tag in the repo, newline separated
tags_in() {
  git -C "$1" tag
}
