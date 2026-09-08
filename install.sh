#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*" >&2; }
err()  { echo -e "${RED}[install]${NC} $*" >&2; }

check_ffmpeg() {
    if command -v ffmpeg &>/dev/null; then
        local version
        version=$(ffmpeg -version 2>&1 | head -1)
        log "ffmpeg already installed: $version"
        return 0
    fi
    return 1
}

install_debian_ubuntu() {
    log "Detected Debian/Ubuntu — installing via apt"
    sudo apt-get update -qq
    sudo apt-get install -y -qq ffmpeg
}

install_fedora() {
    log "Detected Fedora — installing via dnf"
    sudo dnf install -y ffmpeg
}

install_arch() {
    log "Detected Arch Linux — installing via pacman"
    sudo pacman -Sy --noconfirm ffmpeg
}

install_macos() {
    log "Detected macOS — installing via Homebrew"
    if ! command -v brew &>/dev/null; then
        log "Homebrew not found, installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install ffmpeg
}

install_windows() {
    log "Detected Windows (MSYS2/Git Bash environment)"
    if command -v pacman &>/dev/null; then
        log "MSYS2 detected — installing via pacman"
        pacman -S --noconfirm ffmpeg
    elif command -v choco &>/dev/null; then
        log "Chocolatey detected — installing via choco"
        choco install ffmpeg -y
    elif command -v winget &>/dev/null; then
        log "winget detected — installing via winget"
        winget install --id Gyan.FFmpeg -e
    else
        err "No supported package manager found."
        err "Please install ffmpeg manually from https://ffmpeg.org/download.html"
        exit 1
    fi
}

detect_and_install() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian|linuxmint|pop) install_debian_ubuntu ;;
                fedora)                       install_fedora ;;
                arch|manjaro|endeavouros)     install_arch ;;
                *)
                    warn "Unknown distro '$ID' — attempting apt fallback"
                    install_debian_ubuntu
                    ;;
            esac
        else
            warn "Cannot detect distro — attempting apt fallback"
            install_debian_ubuntu
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        install_macos
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
        install_windows
    else
        err "Unsupported OS: $OSTYPE"
        exit 1
    fi
}

generate_test_media() {
    log "Generating test media files..."
    bash "$SCRIPT_DIR/generate_test_media.sh"
}

main() {
    log "=== FFmpeg Benchmark Installer ==="

    if check_ffmpeg; then
        log "Skipping installation."
    else
        detect_and_install
        if ! check_ffmpeg; then
            err "ffmpeg installation failed"
            exit 1
        fi
    fi

    generate_test_media
    log "=== Setup complete ==="
}

main "$@"
