#!/usr/bin/env bash


# Build and publish gor release artifacts for the current GitHub repository.
#
# This release helper produces versioned binaries for the current macOS host and
# Linux, packages each target separately, and publishes them as a single GitHub
# release for the repository tied to the current branch's configured remote.
#
# Run from the repo root after Zig/Cargo prerequisites are installed, or through
# the repo's release task wrapper.
#
# Usage:
#   release.sh v1.2.3
#   release.sh patch
#   release.sh minor
#   release.sh major
#


set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

readonly RELEASE_PACKAGE_NAME="gor"
readonly RELEASE_ASSET_PREFIX="gor"
readonly RELEASE_TARGETS=(
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

main() {
  local script_dir source_file version tmp_dir project_dir

  if [[ $# -eq 0 || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    print_help
    return 0
  fi

  cd "$(repo_root)"
  configure_github_repo

  script_dir="${SCRIPT_DIR}"
  source_file="${script_dir}/gor.rs"
  [[ -f "${source_file}" ]] || die "missing source file ${source_file}."

  version="$(resolve_version "${1:?usage: release.sh <version | patch | minor | major>}")"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  project_dir="${tmp_dir}/cargo-project"
  prepare_cargo_project "${project_dir}" "${source_file}" "${version}"
  build_release_assets "${project_dir}" "${tmp_dir}" "${version}"

  gh release create "${version}" "${ASSETS[@]}" --generate-notes
}

print_help() {
  cat <<'EOF'
Usage: release.sh <version | patch | minor | major>

Builds a macOS host target plus Linux release assets with cargo zigbuild,
zips each artifact, and creates a GitHub release.

Examples:
  release.sh 1.2.3
  release.sh patch
  release.sh minor
  release.sh major
EOF
}

repo_root() {
  cd "${SCRIPT_DIR}/.." && pwd -P
}

die() {
  echo "release.sh: $1" >&2
  exit 1
}

configure_github_repo() {
  local branch remote url rest

  branch="$(git branch --show-current 2>/dev/null || true)"
  [[ -n "${branch}" ]] || die "detached HEAD; checkout a branch first."

  remote="$(git config --get "branch.${branch}.remote" || true)"
  [[ -n "${remote}" ]] || remote="origin"

  url="$(git remote get-url "${remote}" 2>/dev/null)" || die "could not read URL for remote '${remote}'."
  url="${url%.git}"

  if [[ "${url}" =~ ^git@([^:]+):(.+)$ ]]; then
    GH_HOST="${BASH_REMATCH[1]}"
    GH_REPO="${BASH_REMATCH[2]}"
  elif [[ "${url}" =~ ^https?:// ]]; then
    rest="${url#*://}"
    rest="${rest#*@}"
    GH_HOST="${rest%%/*}"
    GH_REPO="${rest#*/}"
    GH_REPO="${GH_REPO%%\?*}"
  fi

  [[ -n "${GH_REPO}" ]] || die "cannot parse GitHub owner/repo from remote '${remote}': ${url}"

  if [[ "${GH_HOST}" == "github.com" || "${GH_HOST}" == "ssh.github.com" ]]; then
    unset GH_HOST
    export GH_REPO
    echo "release.sh: GitHub repo ${GH_REPO} (git remote: ${remote})" >&2
  else
    export GH_HOST GH_REPO
    echo "release.sh: GitHub repo ${GH_REPO} (${GH_HOST}) (git remote: ${remote})" >&2
  fi
}

resolve_version() {
  local ver_raw="$1" bump latest t major minor patch ver

  case "${ver_raw}" in
    patch|minor|major)
      bump="${ver_raw}"
      latest="$(gh api "repos/${GH_REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)"
      if [[ -z "${latest:-}" ]]; then
        case "${bump}" in
          patch) ver="v0.0.1" ;;
          minor) ver="v0.1.0" ;;
          major) ver="v1.0.0" ;;
        esac
        echo "No GitHub latest release; using ${ver}" >&2
      else
        t="${latest#v}"
        if [[ "${t}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
          major="${BASH_REMATCH[1]}"
          minor="${BASH_REMATCH[2]}"
          patch="${BASH_REMATCH[3]}"
          case "${bump}" in
            patch)
              ver="v${major}.${minor}.$((10#${patch} + 1))"
              echo "Bumped patch: ${latest} -> ${ver}" >&2
              ;;
            minor)
              ver="v${major}.$((10#${minor} + 1)).0"
              echo "Bumped minor: ${latest} -> ${ver}" >&2
              ;;
            major)
              ver="v$((10#${major} + 1)).0.0"
              echo "Bumped major: ${latest} -> ${ver}" >&2
              ;;
          esac
        else
          die "Latest release tag '${latest}' is not major.minor.patch; pass an explicit version."
        fi
      fi
      ;;
    *)
      ver="${ver_raw}"
      [[ "${ver}" =~ ^v ]] || ver="v${ver}"
      ;;
  esac

  printf '%s' "${ver}"
}

prepare_cargo_project() {
  local project_dir="$1" source_file="$2" version="$3"

  mkdir -p "${project_dir}/src"
  cp "${source_file}" "${project_dir}/src/main.rs"

  cat >"${project_dir}/Cargo.toml" <<EOF
[package]
name = "${RELEASE_PACKAGE_NAME}"
version = "${version#v}"
edition = "2021"

[profile.release]
strip = true
EOF
}

build_release_assets() {
  local project_dir="$1" tmp_dir="$2" version="$3"
  local target binary_name target_dir built_binary asset_name asset_path staging_dir
  ASSETS=()

  for target in "$(host_macos_target)" "${RELEASE_TARGETS[@]}"; do
    echo "release.sh: building ${target}" >&2
    cargo zigbuild --release --target "${target}" --manifest-path "${project_dir}/Cargo.toml"

    binary_name="${RELEASE_PACKAGE_NAME}"

    target_dir="${project_dir}/target/${target}/release"
    built_binary="${target_dir}/${binary_name}"
    [[ -f "${built_binary}" ]] || die "missing built binary ${built_binary}."

    asset_name="${RELEASE_ASSET_PREFIX}-${version}-${target}.zip"
    asset_path="${tmp_dir}/${asset_name}"
    staging_dir="${tmp_dir}/stage-${target}"
    mkdir -p "${staging_dir}"
    cp "${built_binary}" "${staging_dir}/${binary_name}"
    (cd "${staging_dir}" && zip -qr "${asset_path}" "${binary_name}")
    ASSETS+=("${asset_path}")
  done
}

host_macos_target() {
  case "$(uname -m)" in
    arm64) printf '%s' "aarch64-apple-darwin" ;;
    x86_64) printf '%s' "x86_64-apple-darwin" ;;
    *) die "unsupported macOS architecture '$(uname -m)'." ;;
  esac
}

main "$@"
