#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DESKTOP_DIR/../.." && pwd)"

APP_NAME="Paseo"
OS_NAME=""
SKIP_BUILD=0
LAUNCH=1
ELECTRON_ARCH=""
PACKAGE_FORMAT=""

usage() {
  cat <<'EOF'
Build a local desktop app for the current OS and install it.

Usage:
  install-local-desktop.sh [options]

Options:
  --skip-build        Install from existing release artifacts instead of rebuilding
  --no-launch         Do not open Paseo after installation
  --arch <arch>       Target architecture: arm64 or x64 (default: current machine)
  --format <format>   Linux package format: deb, rpm, or appimage (default: auto)
  -h, --help          Show this help

Examples:
  npm run install:desktop
  npm run install:desktop -- --skip-build --no-launch
  npm run install:desktop -- --format appimage
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

detect_os() {
  case "$(uname -s)" in
    Darwin) OS_NAME="macos" ;;
    Linux) OS_NAME="linux" ;;
    MINGW* | MSYS* | CYGWIN*) die "Windows local install is not supported by this script yet" ;;
    *) die "unsupported operating system: $(uname -s)" ;;
  esac
}

resolve_arch() {
  if [ -n "$ELECTRON_ARCH" ]; then
    return
  fi

  case "$(uname -m)" in
    arm64 | aarch64) ELECTRON_ARCH="arm64" ;;
    x86_64 | amd64) ELECTRON_ARCH="x64" ;;
    *) die "unsupported machine architecture: $(uname -m)" ;;
  esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-build)
        SKIP_BUILD=1
        ;;
      --no-launch)
        LAUNCH=0
        ;;
      --arch)
        shift
        ELECTRON_ARCH="${1:-}"
        [ -n "$ELECTRON_ARCH" ] || die "--arch requires a value"
        ;;
      --format)
        shift
        PACKAGE_FORMAT="${1:-}"
        [ -n "$PACKAGE_FORMAT" ] || die "--format requires a value"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
    shift
  done

  case "$ELECTRON_ARCH" in
    "" | arm64 | x64) ;;
    *) die "unsupported architecture: $ELECTRON_ARCH (expected arm64 or x64)" ;;
  esac

  case "$PACKAGE_FORMAT" in
    "" | deb | rpm | appimage) ;;
    *) die "unsupported format: $PACKAGE_FORMAT (expected deb, rpm, or appimage)" ;;
  esac
}

find_release_artifact() {
  local suffix="$1"
  local matches=()

  shopt -s nullglob
  matches=("$DESKTOP_DIR/release"/*"${suffix}")
  shopt -u nullglob

  if [ "${#matches[@]}" -eq 0 ]; then
    die "no ${suffix} artifact found in ${DESKTOP_DIR}/release"
  fi

  if [ "${#matches[@]}" -gt 1 ]; then
    local newest="${matches[0]}"
    local candidate
    for candidate in "${matches[@]}"; do
      if [ "$candidate" -nt "$newest" ]; then
        newest="$candidate"
      fi
    done
    log "Multiple ${suffix} artifacts found; using ${newest}"
    printf '%s\n' "$newest"
    return
  fi

  printf '%s\n' "${matches[0]}"
}

quit_running_app() {
  if ! pgrep -xq "$APP_NAME"; then
    return
  fi

  log "Quitting running ${APP_NAME}..."

  case "$OS_NAME" in
    macos)
      osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
      ;;
    linux)
      pkill -x "$APP_NAME" >/dev/null 2>&1 || true
      ;;
  esac

  for _ in $(seq 1 40); do
    if ! pgrep -xq "$APP_NAME"; then
      return
    fi
    sleep 0.25
  done

  die "${APP_NAME} is still running; quit it manually and rerun"
}

build_desktop() {
  log "Building desktop app (${OS_NAME}, ${ELECTRON_ARCH})..."

  (
    cd "$ROOT_DIR"
    export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=8192}"

    case "$OS_NAME" in
      macos)
        export CSC_IDENTITY_AUTO_DISCOVERY=false
        npm run build:desktop -- --publish never --mac "--${ELECTRON_ARCH}" --dir \
          -c.mac.hardenedRuntime=false \
          -c.mac.notarize=false \
          -c.mac.identity=null
        ;;
      linux)
        local linux_target="$PACKAGE_FORMAT"
        if [ -z "$linux_target" ]; then
          linux_target="$(detect_linux_package_format)"
        fi
        npm run build:desktop -- --publish never --linux "--${ELECTRON_ARCH}" \
          "-c.linux.target=${linux_target}"
        ;;
    esac
  )
}

detect_linux_package_format() {
  if command -v dpkg >/dev/null 2>&1; then
    printf 'deb\n'
    return
  fi

  if command -v rpm >/dev/null 2>&1; then
    printf 'rpm\n'
    return
  fi

  printf 'appimage\n'
}

install_macos() {
  local built_app="${DESKTOP_DIR}/release/mac-${ELECTRON_ARCH}/${APP_NAME}.app"
  local install_path="/Applications/${APP_NAME}.app"

  [ -d "$built_app" ] || die "built app not found at ${built_app}"

  log "Applying ad-hoc signature for local install..."
  codesign --force --deep --sign - "$built_app"
  xattr -cr "$built_app"

  log "Installing to ${install_path}..."
  rm -rf "$install_path"
  ditto "$built_app" "$install_path"
  xattr -cr "$install_path"

  INSTALLED_PATH="$install_path"
  if [ -f "${install_path}/Contents/Info.plist" ]; then
    INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${install_path}/Contents/Info.plist")"
  else
    INSTALLED_VERSION="unknown"
  fi
}

install_linux() {
  local format="$PACKAGE_FORMAT"
  if [ -z "$format" ]; then
    format="$(detect_linux_package_format)"
  fi

  case "$format" in
    deb)
      install_linux_deb
      ;;
    rpm)
      install_linux_rpm
      ;;
    appimage)
      install_linux_appimage
      ;;
    *)
      die "unsupported Linux format: ${format}"
      ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

install_linux_deb() {
  require_command dpkg
  require_command sudo

  local deb_file
  deb_file="$(find_release_artifact ".deb")"

  log "Installing ${deb_file} with dpkg..."
  sudo dpkg -i "$deb_file" || {
    if command -v apt-get >/dev/null 2>&1; then
      log "Repairing package dependencies..."
      sudo apt-get install -f -y
    else
      die "dpkg install failed"
    fi
  }

  INSTALLED_PATH="/opt/${APP_NAME}/${APP_NAME}"
  if command -v dpkg-query >/dev/null 2>&1; then
    INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' paseo 2>/dev/null || printf 'unknown\n')"
  else
    INSTALLED_VERSION="unknown"
  fi
}

install_linux_rpm() {
  require_command rpm
  require_command sudo

  local rpm_file
  rpm_file="$(find_release_artifact ".rpm")"

  log "Installing ${rpm_file} with rpm..."
  sudo rpm -Uvh --replacepkgs "$rpm_file"

  INSTALLED_PATH="/opt/${APP_NAME}/${APP_NAME}"
  INSTALLED_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' paseo 2>/dev/null || printf 'unknown\n')"
}

install_linux_appimage() {
  local appimage_file
  local install_dir="${HOME}/.local/opt/paseo"
  local bin_path="${HOME}/.local/bin/Paseo.AppImage"
  local desktop_dir="${HOME}/.local/share/applications"
  local desktop_file="${desktop_dir}/paseo-local.desktop"

  appimage_file="$(find_release_artifact ".AppImage")"

  log "Installing AppImage to ${bin_path}..."
  mkdir -p "${HOME}/.local/bin" "$install_dir" "$desktop_dir"
  install -m 755 "$appimage_file" "$bin_path"

  cat >"$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Paseo (local)
Comment=Locally built Paseo desktop app
Exec=${bin_path}
Icon=paseo
Terminal=false
Categories=Development;
StartupWMClass=Paseo
EOF

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
  fi

  INSTALLED_PATH="$bin_path"
  INSTALLED_VERSION="$(basename "$appimage_file")"
}

launch_app() {
  log "Launching ${APP_NAME}..."

  case "$OS_NAME" in
    macos)
      open -a "$APP_NAME"
      ;;
    linux)
      if [ -x "${INSTALLED_PATH}" ]; then
        "$INSTALLED_PATH" >/dev/null 2>&1 &
        return
      fi

      if command -v gtk-launch >/dev/null 2>&1 && [ -f /usr/share/applications/Paseo.desktop ]; then
        gtk-launch Paseo.desktop >/dev/null 2>&1 &
        return
      fi

      die "could not launch ${APP_NAME}; run ${INSTALLED_PATH} manually"
      ;;
  esac
}

print_header() {
  local install_hint="$1"

  log "══════════════════════════════════════════════════════"
  log "  Paseo local desktop install"
  log "══════════════════════════════════════════════════════"
  log "  OS:           ${OS_NAME}"
  log "  Architecture: ${ELECTRON_ARCH}"
  if [ "$OS_NAME" = "linux" ]; then
    if [ -n "$PACKAGE_FORMAT" ]; then
      log "  Format:       ${PACKAGE_FORMAT}"
    else
      log "  Format:       $(detect_linux_package_format) (auto)"
    fi
  fi
  log "  Install path: ${install_hint}"
  log "══════════════════════════════════════════════════════"
}

main() {
  detect_os
  parse_args "$@"
  resolve_arch

  local install_hint=""
  case "$OS_NAME" in
    macos) install_hint="/Applications/${APP_NAME}.app" ;;
    linux)
      if [ -n "$PACKAGE_FORMAT" ]; then
        case "$PACKAGE_FORMAT" in
          deb | rpm) install_hint="/opt/${APP_NAME}/${APP_NAME}" ;;
          appimage) install_hint="${HOME}/.local/bin/Paseo.AppImage" ;;
        esac
      else
        case "$(detect_linux_package_format)" in
          deb | rpm) install_hint="/opt/${APP_NAME}/${APP_NAME}" ;;
          appimage) install_hint="${HOME}/.local/bin/Paseo.AppImage" ;;
        esac
      fi
      ;;
  esac

  print_header "$install_hint"
  quit_running_app

  if [ "$SKIP_BUILD" -eq 0 ]; then
    build_desktop
  else
    log "Skipping build; using existing release artifacts"
  fi

  INSTALLED_PATH=""
  INSTALLED_VERSION="unknown"

  case "$OS_NAME" in
    macos) install_macos ;;
    linux) install_linux ;;
  esac

  log "Installed ${APP_NAME} ${INSTALLED_VERSION} at ${INSTALLED_PATH}"

  if [ "$LAUNCH" -eq 1 ]; then
    launch_app
  fi
}

main "$@"
