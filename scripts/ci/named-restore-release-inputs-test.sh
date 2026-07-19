#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/scripts/ci/named-restore-release-inputs.sh"

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "${label}: expected failure" >&2
    exit 1
  fi
}

load_pinned_release_identity v0.12.0 spore_Darwin_arm64.tar.gz
[[ "${pinned_archive_sha256}" == "19c0f8bcf1ad2e3706b81379658bdfcfdebb88bd090171909d1e9c608226a098" ]]
[[ "${pinned_archive_member}" == "spore_Darwin_arm64/bin/spore" ]]
load_pinned_release_identity v0.12.0 spore_Linux_arm64.tar.gz
[[ "${pinned_archive_sha256}" == "b9779ec3bff952d6748a06730612916fc8f11c71cd30745cff8a88d3c7e39408" ]]
[[ "${pinned_archive_member}" == "spore_Linux_arm64/bin/spore" ]]
[[ "${pinned_checksums_sha256}" == "73661f6a7d68a26781ded4da18726ca620edc92394c4d9b6f9984b3954941b5e" ]]
expect_failure "wrong version" load_pinned_release_identity v0.12.1 spore_Linux_arm64.tar.gz
expect_failure "replacement override" require_pinned_reassertion deadbeef "${pinned_archive_sha256}" archive
require_pinned_reassertion "${pinned_archive_sha256}" "${pinned_archive_sha256}" archive
expect_failure "mutable image" require_digest_image docker.io/library/node:22-alpine
require_digest_image docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271

export SPOREVM_BENCHMARK_SCRATCH_ROOT=/var/tmp/nvme/sporevm-benchmarks
unset SPOREVM_NAMED_RESTORE_SCRATCH_ROOT
[[ "$(named_restore_scratch_root kvm "${repo_root}")" == "${repo_root}/zig-cache/named-restore-scratch" ]]
export SPOREVM_NAMED_RESTORE_SCRATCH_ROOT=/task-owned/ext4
[[ "$(named_restore_scratch_root kvm "${repo_root}")" == "/task-owned/ext4" ]]
unset SPOREVM_BENCHMARK_SCRATCH_ROOT SPOREVM_NAMED_RESTORE_SCRATCH_ROOT
export TMPDIR=/private/runner/path/that/must/not/own/named-restore
[[ "$(named_restore_scratch_root hvf "${repo_root}")" == "/tmp" ]]
unset TMPDIR
grep -F 'SPOREVM_NAMED_RESTORE_SCRATCH_ROOT: "/var/tmp/sporevm-named-restore-verity"' \
  "${repo_root}/.buildkite/pipeline.yml" >/dev/null

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-release-inputs-test.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
fake_bin="${workdir}/bin"
mkdir -p "${fake_bin}"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${FAKE_FINDMNT_TYPE:?}"\n' > "${fake_bin}/findmnt"
chmod +x "${fake_bin}/findmnt"
old_path="${PATH}"
export PATH="${fake_bin}:${PATH}"
export FAKE_FINDMNT_TYPE=ext4
require_named_restore_scratch_filesystem kvm "${workdir}"
export FAKE_FINDMNT_TYPE=zfs
expect_failure "ordinary KVM ZFS release scratch" \
  require_named_restore_scratch_filesystem kvm "${workdir}"
unset FAKE_FINDMNT_TYPE
export PATH="${old_path}"
asset="fixture.tar.gz"
archive="${workdir}/${asset}"
checksums="${workdir}/checksums.txt"
printf 'reviewed archive bytes\n' > "${archive}"
archive_sha256="$(sha256_path "${archive}")"
printf '%s  %s\n' "${archive_sha256}" "${asset}" > "${checksums}"
checksums_sha256="$(sha256_path "${checksums}")"
verify_pinned_release_assets "${checksums}" "${archive}" "${asset}" "${checksums_sha256}" "${archive_sha256}"

expect_failure "wrong checksum file" verify_pinned_release_assets \
  "${checksums}" "${archive}" "${asset}" "$(printf '0%.0s' {1..64})" "${archive_sha256}"

wrong_entry_checksums="${workdir}/wrong-entry.txt"
printf '%064d  %s\n' 0 "${asset}" > "${wrong_entry_checksums}"
expect_failure "wrong checksum entry" verify_pinned_release_assets \
  "${wrong_entry_checksums}" "${archive}" "${asset}" "$(sha256_path "${wrong_entry_checksums}")" "${archive_sha256}"

wrong_archive="${workdir}/wrong-archive.tar.gz"
printf 'replacement archive bytes\n' > "${wrong_archive}"
expect_failure "wrong archive" verify_pinned_release_assets \
  "${checksums}" "${wrong_archive}" "${asset}" "${checksums_sha256}" "${archive_sha256}"

echo "release input/scratch self-test ok"
