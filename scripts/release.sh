#!/usr/bin/env bash

# Publish a GitHub release using pre-built zip artifacts from gor/dist/.
# Run ``./scripts/build-cross.sh <version>`` first (same version string).
# Tags HEAD and pushes to ``origin``, then runs ``gh release create``.
#
# Run from anywhere; paths are resolved from this script.
#
# Usage:
#   ./scripts/release.sh <version | patch | minor | major>
#
# Dependencies:
#   - git
#   - GitHub CLI: gh, authenticated for the repo (e.g. brew install gh; gh auth login)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly RELEASE_ASSET_PREFIX="gor"

main() {
  local version dist_dir

  if [[ $# -eq 0 || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    print_help
    return 0
  fi

  if [[ ${1:-} == "--resolve-version" ]]; then
    if [[ $# -ne 2 ]]; then
      die "usage: release.sh --resolve-version <patch|minor|major>"
    fi
    case "${2}" in
      patch|minor|major) ;;
      *) die "--resolve-version only accepts patch, minor, or major" ;;
    esac
    cd "$(repo_root)"
    configure_github_repo
    resolve_version "$2"
    return 0
  fi

  cd "$(repo_root)"
  configure_github_repo

  version="$(resolve_version "${1:?usage: release.sh <version | patch | minor | major>}")"

  dist_dir="${GOR_ROOT}/dist"
  [[ -d "${dist_dir}" ]] || die "missing dist dir ${dist_dir}; run scripts/build-cross.sh ${version} first."

  ASSETS=()
  shopt -s nullglob
  ASSETS=("${dist_dir}/${RELEASE_ASSET_PREFIX}-${version}"-*.zip)
  shopt -u nullglob
  [[ ${#ASSETS[@]} -ge 1 ]] || die \
    "no zips matching ${dist_dir}/${RELEASE_ASSET_PREFIX}-${version}-*.zip; run scripts/build-cross.sh ${version} first."

  git_annotated_release_tag_add "${version}"
  gh release create "${version}" "${ASSETS[@]}" --generate-notes
}

print_help() {
  cat <<'EOF'
Usage: release.sh <version | patch | minor | major>

Tags HEAD, pushes the tag to origin, then creates a GitHub release from pre-built zips in
gor/dist/ (see scripts/build-cross.sh).

Dependencies:
  git     repository root and remote URL for gh
  gh      brew install gh; gh auth login

Examples:
  ./scripts/build-cross.sh 1.2.3 && ./scripts/release.sh 1.2.3
EOF
}

repo_root() {
  cd "${SCRIPT_DIR}" && git rev-parse --show-toplevel
}

die() {
  echo "release.sh: $1" >&2
  exit 1
}

## Annotated tag ``tag`` at HEAD (replaces the local tag if it already exists).
git_annotated_release_tag_add() {
  local tag="$1"
  git tag -af "${tag}" -m "gor ${tag}"
  git push --force origin "${tag}"
  echo "release.sh: tagged ${tag}" >&2
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
          patch) ver="0.0.1" ;;
          minor) ver="0.1.0" ;;
          major) ver="1.0.0" ;;
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
              ver="${major}.${minor}.$((10#${patch} + 1))"
              echo "Bumped patch: ${latest} -> ${ver}" >&2
              ;;
            minor)
              ver="${major}.$((10#${minor} + 1)).0"
              echo "Bumped minor: ${latest} -> ${ver}" >&2
              ;;
            major)
              ver="$((10#${major} + 1)).0.0"
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
      if [[ "${ver}" =~ ^v[0-9] ]]; then
        ver="${ver#v}"
      fi
      ;;
  esac

  printf '%s' "${ver}"
}

main "$@"
