#!/usr/bin/env bash

sha256_path() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

named_restore_scratch_root() {
  local backend="$1"
  local repo_root="$2"
  if [[ "${backend}" == "kvm" ]]; then
    printf '%s\n' "${SPOREVM_NAMED_RESTORE_SCRATCH_ROOT:-${repo_root}/zig-cache/named-restore-scratch}"
  else
    printf '%s\n' "${SPOREVM_NAMED_RESTORE_SCRATCH_ROOT:-/tmp}"
  fi
}

require_named_restore_scratch_filesystem() {
  local backend="$1"
  local path="$2"
  local filesystem
  [[ "${backend}" == "kvm" ]] || return 0
  command -v findmnt >/dev/null 2>&1 || {
    echo "named-restore Linux release scratch requires findmnt" >&2
    return 1
  }
  filesystem="$(findmnt --noheadings --output FSTYPE --target "${path}" 2>/dev/null | awk 'NF { print $1; exit }')"
  if [[ "${filesystem}" != "ext4" ]]; then
    echo "named-restore Linux release scratch must be ext4, got ${filesystem:-unknown}: ${path}" >&2
    return 1
  fi
}

load_pinned_release_identity() {
  local version="$1"
  local asset="$2"

  pinned_checksums_sha256="73661f6a7d68a26781ded4da18726ca620edc92394c4d9b6f9984b3954941b5e"
  case "${version}/${asset}" in
    v0.12.0/spore_Darwin_arm64.tar.gz)
      pinned_archive_sha256="19c0f8bcf1ad2e3706b81379658bdfcfdebb88bd090171909d1e9c608226a098"
      pinned_archive_member="spore_Darwin_arm64/bin/spore"
      ;;
    v0.12.0/spore_Linux_arm64.tar.gz)
      pinned_archive_sha256="b9779ec3bff952d6748a06730612916fc8f11c71cd30745cff8a88d3c7e39408"
      pinned_archive_member="spore_Linux_arm64/bin/spore"
      ;;
    *)
      echo "unsupported named-restore baseline identity: ${version}/${asset}" >&2
      return 1
      ;;
  esac
}

require_pinned_reassertion() {
  local supplied="$1"
  local pinned="$2"
  local label="$3"
  if [[ -n "${supplied}" && "${supplied}" != "${pinned}" ]]; then
    echo "${label} override does not match the repository-pinned identity" >&2
    return 1
  fi
}

require_digest_image() {
  local image="$1"
  if [[ ! "${image}" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "named-restore release image must be an exact digest-pinned reference" >&2
    return 1
  fi
}

verify_pinned_release_assets() {
  local checksums="$1"
  local archive="$2"
  local asset="$3"
  local expected_checksums_sha256="$4"
  local expected_archive_sha256="$5"
  local actual_checksums_sha256
  local actual_archive_sha256
  local entry_count
  local release_sha256

  actual_checksums_sha256="$(sha256_path "${checksums}")"
  if [[ "${actual_checksums_sha256}" != "${expected_checksums_sha256}" ]]; then
    echo "baseline checksums SHA-256 mismatch: expected ${expected_checksums_sha256}, got ${actual_checksums_sha256}" >&2
    return 1
  fi

  entry_count="$(awk -v asset="${asset}" '$2 == asset || $2 == "*" asset { count++ } END { print count + 0 }' "${checksums}")"
  release_sha256="$(awk -v asset="${asset}" '$2 == asset || $2 == "*" asset { print $1 }' "${checksums}")"
  if [[ "${entry_count}" -ne 1 || "${release_sha256}" != "${expected_archive_sha256}" ]]; then
    echo "baseline checksums do not contain the pinned SHA-256 for ${asset}" >&2
    return 1
  fi

  actual_archive_sha256="$(sha256_path "${archive}")"
  if [[ "${actual_archive_sha256}" != "${expected_archive_sha256}" ]]; then
    echo "baseline archive SHA-256 mismatch: expected ${expected_archive_sha256}, got ${actual_archive_sha256}" >&2
    return 1
  fi
}
