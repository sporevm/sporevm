---
name: release-sporevm
description: Cut, publish, or assess SporeVM releases from the sporevm/sporevm repository. Use when a user asks to prepare a version bump, tag a new SporeVM release, verify release readiness, watch Buildkite release publishing, update GitHub release notes, or debug duplicate/missing tag-build release behavior.
---

# Release SporeVM

Release from fresh `origin/main`, not from whatever branch is checked out.
The repo's release path is already in `mise.toml`, `scripts/release.sh`,
`scripts/prepare-release.sh`, and `.buildkite/pipeline.yml`; use those instead
of inventing release commands.

## Workflow

1. Fetch and orient:
   ```bash
   git fetch origin --tags --prune
   git status --short --branch
   gh release list --repo sporevm/sporevm --limit 10
   git log --oneline <last-tag>..origin/main
   ```
   Check live PR, GitHub status, and Buildkite state before making a release
   call. Use `svu next` or commit scope to pick the version, but set the final
   tag explicitly as `vMAJOR.MINOR.PATCH`.

2. Prepare the version bump through a PR:
   ```bash
   git switch -c lox/release-vX.Y.Z origin/main
   MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise run release:prepare -- vX.Y.Z
   MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise run check
   ./zig-out/bin/spore version
   git-assume bk-codex
   git add build.zig src/version.zig
   git commit -m "chore: Bump version to vX.Y.Z"
   git push -u origin lox/release-vX.Y.Z
   ```
   PR title should be `chore: Bump version to vX.Y.Z`. Keep the PR body short:
   why the release is needed and what user-visible changes it carries. Do not
   add a validations section.

3. Merge only after the PR Buildkite status is green. If `origin/main` moves
   before merge, rebase the bump branch onto `origin/main`, rerun
   `mise run check`, and force-push with lease.

4. After merge, wait for the `main` Buildkite status on the merge commit to pass:
   ```bash
   gh api repos/sporevm/sporevm/commits/$(git rev-parse origin/main)/status \
     --jq '{state: .state, statuses: [.statuses[] | {context,state,description,target_url}]}'
   bk build view -p buildkite/sporevm <main-build-number>
   ```
   The benchmark trigger is async on `main`; do not block release tagging on the
   child benchmark build unless the main status fails or the user asks.

5. Tag exactly once from detached `origin/main`:
   ```bash
   git fetch origin --tags --prune
   git tag -l vX.Y.Z
   gh release view vX.Y.Z --repo sporevm/sporevm || true
   git switch --detach origin/main
   SPOREVM_RELEASE_VERSION=vX.Y.Z \
     MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
     mise run release
   ```
   Stop if the tag or release already exists. Do not delete and recreate a
   version tag to rerun publishing; watch or debug the existing tag build.

6. Watch the tag build and verify publishing:
   ```bash
   tag_sha="$(git rev-list -n 1 vX.Y.Z)"
   bk build list -p buildkite/sporevm --branch vX.Y.Z --commit "$tag_sha" --limit 10 --json
   bk build view -p buildkite/sporevm <tag-build-number>
   gh release view vX.Y.Z --repo sporevm/sporevm \
     --json tagName,name,isDraft,isPrerelease,publishedAt,url,assets
   ```
   Expected assets are `checksums.txt`, `spore_Darwin_arm64.tar.gz`,
   `spore_Linux_arm64.tar.gz`, `libspore_Darwin.tar.gz`, and
   `libspore_Linux.tar.gz`. The benchmark trigger can be skipped/broken on tag
   builds; the release archive and publish jobs must pass.

## Notes

- `mise run release` already runs `mise run check` before tagging.
- Do not run manual smoke commands by default; add them only when the user asks
  or the release risk clearly needs hardware/runtime proof.
- Generated GitHub release notes match recent SporeVM releases: `## What's
  Changed`, PR bullets, then `Full Changelog`. Edit notes only when the user
  asks for human-written notes.
