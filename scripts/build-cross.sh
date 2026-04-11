#!/usr/bin/env bash

# Cross-compile gor: macOS host binary plus Linux glibc (x86_64, aarch64) via Nim + zig cc.
# Writes versioned zip artifacts under gor/dist/ (gitignored).
#
# Run from anywhere; paths are resolved from this script.
#
# Usage:
#   ./scripts/build-cross.sh [version]
#
# version defaults to "dev" and is used in zip names (e.g. gor-dev-aarch64-apple-darwin.zip).
#
# Dependencies:
#   - nim (2.0+), nimble (gor.nimble deps, e.g. cligen)
#   - zig (Linux cross-compiles)
#   - zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly RELEASE_PACKAGE_NAME="gor"
readonly RELEASE_ASSET_PREFIX="gor"
readonly RELEASE_TARGETS=(
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

die() {
  echo "build-cross.sh: $1" >&2
  exit 1
}

require_nim() {
  if command -v nim &>/dev/null; then
    return 0
  fi
  echo "build-cross.sh: nim not found on PATH." >&2
  echo "  https://nim-lang.org/install.html" >&2
  exit 1
}

require_zig() {
  if command -v zig &>/dev/null; then
    return 0
  fi
  echo "build-cross.sh: zig not found on PATH (needed for Linux cross-compiles)." >&2
  echo "  macOS: brew install zig" >&2
  echo "  https://ziglang.org/download/" >&2
  exit 1
}

zig_cc_wrapper_path() {
  local tmp_dir="$1" zig_target="$2" wrapper

  wrapper="${tmp_dir}/zig-cc-${zig_target//[^a-zA-Z0-9_-]/_}"
  cat >"${wrapper}" <<EOF
#!/usr/bin/env sh
exec zig cc -target ${zig_target} "\$@"
EOF
  chmod +x "${wrapper}"
  printf '%s' "${wrapper}"
}

strip_binary() {
  local binary="$1"

  if ! command -v strip &>/dev/null; then
    return 0
  fi
  strip "${binary}" 2>/dev/null || true
}

build_nim_host_macos() {
  local source_file="$1" output_binary="$2"

  echo "build-cross.sh: building $(host_macos_target)" >&2
  nim c -d:release --hints:off --verbosity:0 -o:"${output_binary}" "${source_file}"
  strip_binary "${output_binary}"
}

build_nim_linux() {
  local source_file="$1" output_binary="$2" tmp_dir="$3" zig_target="$4" cpu="$5"

  local wrapper
  wrapper="$(zig_cc_wrapper_path "${tmp_dir}" "${zig_target}")"

  echo "build-cross.sh: building ${zig_target} (Nim --os:Linux --cpu:${cpu})" >&2
  nim c -d:release --hints:off --verbosity:0 --passL:-s \
    --os:Linux --cpu:"${cpu}" \
    --cc:clang \
    --clang.exe:"${wrapper}" \
    --clang.linkerexe:"${wrapper}" \
    -o:"${output_binary}" \
    "${source_file}"
}

host_macos_target() {
  case "$(uname -m)" in
    arm64) printf '%s' "aarch64-apple-darwin" ;;
    x86_64) printf '%s' "x86_64-apple-darwin" ;;
    *) die "unsupported macOS architecture '$(uname -m)'." ;;
  esac
}

build_release_zips() {
  local source_file="$1" dist_dir="$2" version="$3" tmp_dir="$4"
  local target binary_name asset_name asset_path staging_dir built_binary zig_target cpu

  binary_name="${RELEASE_PACKAGE_NAME}"

  target="$(host_macos_target)"
  built_binary="${tmp_dir}/build-${target}/${binary_name}"
  mkdir -p "$(dirname "${built_binary}")"
  build_nim_host_macos "${source_file}" "${built_binary}"
  [[ -f "${built_binary}" ]] || die "missing built binary ${built_binary}."
  asset_name="${RELEASE_ASSET_PREFIX}-${version}-${target}.zip"
  asset_path="${dist_dir}/${asset_name}"
  staging_dir="${tmp_dir}/stage-${target}"
  mkdir -p "${staging_dir}"
  cp "${built_binary}" "${staging_dir}/${binary_name}"
  (cd "${staging_dir}" && zip -qr "${asset_path}" "${binary_name}")
  echo "build-cross.sh: wrote ${asset_path}" >&2

  for target in "${RELEASE_TARGETS[@]}"; do
    zig_target=""
    cpu=""
    case "${target}" in
      aarch64-unknown-linux-gnu)
        zig_target="aarch64-linux-gnu"
        cpu="arm64"
        ;;
      x86_64-unknown-linux-gnu)
        zig_target="x86_64-linux-gnu"
        cpu="amd64"
        ;;
      *)
        die "unsupported Linux target '${target}'."
        ;;
    esac

    built_binary="${tmp_dir}/build-${target}/${binary_name}"
    mkdir -p "$(dirname "${built_binary}")"
    build_nim_linux "${source_file}" "${built_binary}" "${tmp_dir}" "${zig_target}" "${cpu}"
    [[ -f "${built_binary}" ]] || die "missing built binary ${built_binary}."

    asset_name="${RELEASE_ASSET_PREFIX}-${version}-${target}.zip"
    asset_path="${dist_dir}/${asset_name}"
    staging_dir="${tmp_dir}/stage-${target}"
    mkdir -p "${staging_dir}"
    cp "${built_binary}" "${staging_dir}/${binary_name}"
    (cd "${staging_dir}" && zip -qr "${asset_path}" "${binary_name}")
    echo "build-cross.sh: wrote ${asset_path}" >&2
  done
}

main() {
  local version source_file dist_dir

  version="${1:-dev}"
  [[ "${version}" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "version must be a safe filename token (got: ${version})"

  require_nim
  require_zig

  source_file="${GOR_ROOT}/gor.nim"
  [[ -f "${source_file}" ]] || die "missing source file ${source_file}."

  dist_dir="${GOR_ROOT}/dist"
  mkdir -p "${dist_dir}"

  cd "${GOR_ROOT}"
  nimble install -y --depsOnly

  # Must be global so the EXIT trap still sees it under ``set -u`` after ``main`` returns.
  build_cross_tmp="$(mktemp -d)"
  trap 'rm -rf -- "${build_cross_tmp}"' EXIT

  build_release_zips "${source_file}" "${dist_dir}" "${version}" "${build_cross_tmp}"
  echo "build-cross.sh: done. Artifacts in ${dist_dir}/" >&2
}

main "$@"
