# Go Cut Tag

![Latest Release](https://img.shields.io/github/v/release/p6m-actions/golang-cut-tag?style=flat-square&label=Latest%20Release&color=blue)

## Description

Cuts a semantic-version git tag for a Go module.

**Why this one is tag-driven, unlike its siblings.** Every other ecosystem keeps the version in a
file its cut-tag action rewrites — `Cargo.toml`, `package.json`, the `.csproj`, the `pom`. A Go
module has no such field: `go.mod` states the module path and the language version, never the
module's own version. For Go the **git tag is the version**, and `go get` resolves releases by
reading tags. So there is nothing to bump and nothing to commit — this action reads the latest tag,
computes the next one, and tags.

That also makes it work unchanged on a **legacy repository being retrofitted**, which has no version
file to add. The version-line file is therefore optional here (it is required by
[`git-cut-tag`](https://github.com/p6m-actions/git-cut-tag)): when present it is a floor the
maintainer controls, and when absent the latest tag alone decides.

## Usage

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0        # tags must be available
- uses: p6m-actions/golang-cut-tag@v1
  id: tag
  with:
    version-level: patch
- run: echo "Cut ${{ steps.tag.outputs.tag }}"
```

### Required permissions

```yaml
permissions:
  contents: write
```

## The optional version file

A single line containing the prefix and the `major.minor` line:

```
v1.2
```

- The **prefix** is the leading non-digit characters (`v` here); override with the `prefix` input.
  With no file at all the prefix defaults to `v`, which is what `go get` expects.
- The **major.minor** is a floor. Bumping it (e.g. to `v1.3`) makes the next release `v1.3.0`
  regardless of the latest tag. The file is read-only: this action never writes it and never
  creates a commit.
- An **empty or malformed** file is an error rather than a silent floor of zero — a file that exists
  is assumed to mean something.

## How the next version is computed

1. Read the floor `major.minor` and prefix from the version file, if there is one (otherwise `0.0`
   and prefix `v`).
2. Find the latest **release** tag with that prefix (pre-release tags are ignored, so a string of
   pre-releases never advances the line). Selection is by semantic-version order, so `v1.10.0`
   beats `v1.9.0`.
3. Bump it by `version-level`. With no existing tag the base is `0.0.0`.
4. If the file's `major.minor` is greater than the bumped result, use the file's line with patch `0`.
5. If `pre-release` is `true`, append `-<epoch-seconds>`.

| Version file | Latest tag | `version-level` | Result tag |
|---|---|---|---|
| *(none)* | *(none)* | `patch` | `v0.0.1` |
| *(none)* | `v0.3.7` | `patch` | `v0.3.8` |
| *(none)* | `v1.4.9` | `minor` | `v1.5.0` |
| *(none)* | `v1.4.9` | `major` | `v2.0.0` |
| `v1.2` | `v1.2.4` | `patch` | `v1.2.5` |
| `v2.0` | `v1.9.9` | `patch` | `v2.0.0` |
| `v1.0` | `v3.4.5` | `patch` | `v3.4.6` |

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| `version-level` | Level to bump relative to the latest tag: `patch`, `minor`, `major` | No | `patch` |
| `version-file` | Optional version-line file acting as a floor | No | `.version-line` |
| `prefix` | Tag prefix. Inferred from the version file when one exists; `v` otherwise | No | `""` |
| `pre-release` | Build a pre-release tag with a trailing epoch timestamp | No | `false` |
| `working-directory` | Directory to operate in (inside the repo) | No | `.` |
| `skip-push` | Skip pushing the tag (useful for testing) | No | `false` |

## Outputs

| Output | Description |
|---|---|
| `version` | New version without prefix (e.g. `1.2.5` or `1.2.5-1782043845`) |
| `tag` | Created git tag with prefix (e.g. `v1.2.5`) |
| `base-version` | Release version without any pre-release suffix |
| `is-pre-release` | `true` when a pre-release tag was created |

## Examples

### Pre-release build on every main push

```yaml
- uses: p6m-actions/golang-cut-tag@v1
  id: tag
  with:
    pre-release: "true"
- run: echo "Built ${{ steps.tag.outputs.tag }} (release line ${{ steps.tag.outputs.base-version }})"
```

### Pin the line with a version file

```yaml
- uses: p6m-actions/golang-cut-tag@v1
  with:
    version-file: ".version-line"
    version-level: minor
```

## Development

The version logic lives in `scripts/cut-tag.sh` and is covered by a
[bats](https://github.com/bats-core/bats-core) suite:

```bash
brew install bats-core        # or: sudo apt-get install -y bats
bats tests/cut-tag.bats
```
