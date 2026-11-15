#!/bin/sh
# Installs bla — Blablador on the command line — on Linux (x86-64, Raspberry Pi and other 64-bit ARM boards) and on
# macOS. Downloads the build for this machine from the latest release, checks it against SHA256SUMS.txt and puts it
# in ~/.local/bin, or in /usr/local/bin when it runs as root.
#
#   curl -fsSL https://surak.github.io/blablador-ios/install.sh | sh
#
# With arguments, for a machine or a folder you choose:
#
#   sh install.sh --platform linux-arm64 --dir /usr/local/bin [--version v3.12.1] [--dry-run]
#
# It needs nothing but curl (or wget), tar and a SHA-256 tool — no root, no compiler. To remove bla again, delete
# the binary and, if you like, ~/.bla.
set -eu

REPO=surak/blablador-ios
PLATFORM=
DIR=
VERSION=
DRY_RUN=0

say() { printf '%s\n' "$*"; }
die() {
    printf 'bla install: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --platform) PLATFORM=${2:-}; shift 2 ;;
        --platform=*) PLATFORM=${1#*=}; shift ;;
        --dir) DIR=${2:-}; shift 2 ;;
        --dir=*) DIR=${1#*=}; shift ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --version=*) VERSION=${1#*=}; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            say 'Usage: install.sh [--platform linux-x86_64|linux-arm64|macos-arm64|macos-x86_64] [--dir FOLDER] [--version TAG] [--dry-run]'
            exit 0
            ;;
        *) die "unknown option $1 (try --help)" ;;
    esac
done

# ---------- Which build this machine needs ----------

if [ -z "$PLATFORM" ]; then
    case $(uname -s) in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *) die "$(uname -s) is not Linux or macOS; on Windows use install.ps1, or build from source (cargo install --path cli)" ;;
    esac
    case $(uname -m) in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l|armv6l)
            die "32-bit ARM ($(uname -m)) is not built; Raspberry Pi OS 64-bit is. Reinstall with the 64-bit system, or build from source (cargo install --path cli)"
            ;;
        *) die "no build for $(uname -m); see https://github.com/$REPO/releases/latest" ;;
    esac
    PLATFORM=$os-$arch
fi

case $PLATFORM in
    linux-x86_64|linux-arm64|macos-arm64|macos-x86_64) ext=tar.gz ;;
    *) die "unknown platform $PLATFORM (linux-x86_64, linux-arm64, macos-arm64, macos-x86_64)" ;;
esac

# ---------- Where it goes ----------

if [ -z "$DIR" ]; then
    if [ "$(id -u)" = 0 ]; then
        DIR=/usr/local/bin
    else
        DIR=$HOME/.local/bin
    fi
fi

# ---------- Downloading ----------

fetch() { # fetch URL FILE
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$1" -O "$2"
    else
        die 'needs curl or wget'
    fi
}

latest_tag() {
    # The releases/latest redirect ends in /tag/v3.12.1: no GitHub API token, no rate limit.
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI "https://github.com/$REPO/releases/latest" | tr -d '\r' | sed -n 's/^[Ll]ocation: .*\/tag\///p' | tail -1
    else
        wget -q -S --spider "https://github.com/$REPO/releases/latest" 2>&1 | tr -d '\r' | sed -n 's/^ *[Ll]ocation: .*\/tag\///p' | tail -1
    fi
}

[ -n "$VERSION" ] || VERSION=$(latest_tag)
[ -n "$VERSION" ] || die 'could not ask GitHub for the latest version; pass --version v3.12.1'
version=${VERSION#v}
base="https://github.com/$REPO/releases/download/$VERSION"
name="Blablador-$version-bla-$PLATFORM.$ext"

say "bla $version for $PLATFORM -> $DIR/bla"

if [ "$DRY_RUN" = 1 ]; then
    say "would download $base/$name and $base/SHA256SUMS.txt"
    exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bla-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch "$base/$name" "$tmp/$name" || die "could not download $base/$name"
fetch "$base/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt" || die 'could not download SHA256SUMS.txt'

want=$(sed -n "s/^\([0-9a-f]*\)  $name\$/\1/p" "$tmp/SHA256SUMS.txt")
[ -n "$want" ] || die "$name is not in SHA256SUMS.txt"
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)
else
    die 'needs sha256sum or shasum to check the download'
fi
[ "$got" = "$want" ] || die "the download does not match SHA256SUMS.txt ($got, expected $want)"

tar xzf "$tmp/$name" -C "$tmp"
bin=$(find "$tmp" -type f -name bla | head -1)
[ -n "$bin" ] || die 'the archive has no bla in it'
chmod 755 "$bin"

# ---------- Does it start here? ----------

# The build links against the system's ALSA (speech) and D-Bus (keyring) libraries and needs glibc 2.34 or newer, so
# it runs on Raspberry Pi OS bookworm and newer, Debian 12+, Ubuntu 22.04+ and macOS 11+. Say what is missing rather
# than installing a bla that cannot start.
lib_packages() { # lib_packages SONAME -> packages that provide it
    case $1 in
        libasound.so.2)
            case $(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID" | tr -d '"') in
                ubuntu\ 2[4-9]*) echo 'libasound2t64' ;;
                *) echo 'libasound2 (alsa-lib on Fedora, openSUSE and Arch)' ;;
            esac
            ;;
        libdbus-1.so.3) echo 'libdbus-1-3 (dbus-libs on Fedora, openSUSE and Arch)' ;;
        *) echo "$1" ;;
    esac
}

diagnose() { # diagnose ERROR-OUTPUT
    missing=$(printf '%s\n' "$1" | sed -n 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p')
    say ''
    if [ -n "$missing" ]; then
        say "bla needs $missing, which this system does not have. Install it and run this again:"
        for lib in $missing; do
            say "  $(lib_packages "$lib")"
        done
        say ''
        say 'On Debian, Ubuntu and Raspberry Pi OS that is: sudo apt install -y libasound2 libdbus-1-3'
    else
        case $1 in
            *GLIBC_*)
                say "Cannot start here: this system's C library is older than the build needs (glibc 2.34 or newer)."
                say 'bla runs on Raspberry Pi OS bookworm and newer, Debian 12+, Ubuntu 22.04+ and macOS 11+.'
                say 'On an older system, build it from the source: cargo install --path cli'
                ;;
            *)
                say 'The downloaded bla does not start here:'
                say "$1"
                ;;
        esac
    fi
}

if ! run=$("$bin" --version 2>&1); then
    diagnose "$run"
    die 'nothing was installed'
fi
[ "$run" = "bla $version" ] || say "note: the download calls itself '$run'"

# ---------- Installing ----------

mkdir -p "$DIR" 2>/dev/null || die "cannot create $DIR; run with sudo or pass --dir ~/.local/bin"
target=$DIR/bla
# Replace by rename: writing over a running bla fails with "text file busy", a rename does not.
cp "$bin" "$DIR/.bla.new" || die "cannot write to $DIR; run with sudo or pass --dir ~/.local/bin"
chmod 755 "$DIR/.bla.new"
mv -f "$DIR/.bla.new" "$target"

say ''
say "Installed $run as $target"

case :$PATH: in
    *:$DIR:*) ;;
    *)
        say ''
        say "$DIR is not on your PATH. Add it with:"
        shell=${SHELL:-}
        case ${shell##*/} in
            fish) say "  fish_add_path $DIR" ;;
            zsh) say "  echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
            *) say "  echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.profile && . ~/.profile" ;;
        esac
        ;;
esac

if [ ! -f "${BLA_HOME:-$HOME/.bla}/.apikey" ] && [ -z "${BLABLADOR_API_KEY:-}" ]; then
    say ''
    say "Next: $target login   (paste your Blablador API key), then: bla \"hello\""
fi
