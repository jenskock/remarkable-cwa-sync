#!/bin/sh
# Install cwa-sync under /home/root so a reMarkable firmware update keeps it.
# Usage: sh install.sh [--prefix DIR] [--timer] [--fetch-wget]

set -eu -f

SRC=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${PREFIX:-/home/root}
PROFILE=${PROFILE:-$PREFIX/.profile}
INSTALL_TIMER=0
FETCH_WGET=0
WGET_URL=${CWA_FETCH_WGET_URL:-http://toltec-dev.org/thirdparty/bin/wget-v1.21.1-3}
WGET_SHA256=${CWA_FETCH_WGET_SHA256:-3130886a020a56b7471ed60f3742db26acdced4b27fed5be22f9892b77589bc5}

usage() {
    cat <<'EOF'
Usage: install.sh [--prefix DIR] [--timer] [--fetch-wget]

Copies cwa-sync to $PREFIX/cwa-sync (default /home/root), creates a
config from the example if needed, and puts a symlink on
$PREFIX/.local/bin.

  --timer        install a systemd timer (wiped by firmware updates; re-run after an OS update)
  --fetch-wget   download the Toltec static TLS wget into $PREFIX/.local/bin
                 (also done automatically when no HTTPS client is available)

Stock reMarkable wget is BusyBox without HTTPS. The static wget is fetched
over plain HTTP and checked with sha256sum.
EOF
}

die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

have_tls_client() {
    local bin
    if command -v curl >/dev/null 2>&1; then
        if curl --version 2>&1 | grep -E -q 'https|SSL|TLS'; then
            return 0
        fi
    fi
    for bin in "$PREFIX/.local/bin/wget" "$(command -v wget 2>/dev/null || true)"; do
        if [ -z "$bin" ] || [ ! -x "$bin" ]; then
            continue
        fi
        if "$bin" --version 2>&1 | grep -q '+https'; then
            return 0
        fi
        if "$bin" --help 2>&1 | grep -q -i 'https'; then
            return 0
        fi
    done
    return 1
}

fetch_to() {
    local url dest
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 1 -o "$dest" -- "$url"
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url"
        return 0
    fi
    die "need curl or wget to download a TLS client"
}

install_static_wget() {
    local tmp dest
    dest=$PREFIX/.local/bin/wget
    mkdir -p -- "$PREFIX/.local/bin"
    if command -v mktemp >/dev/null 2>&1; then
        tmp=$(mktemp)
    else
        tmp=$PREFIX/.local/bin/wget.partial.$$
    fi
    printf 'install.sh: fetching TLS wget\n' >&2
    if ! fetch_to "$WGET_URL" "$tmp"; then
        rm -f -- "$tmp"
        die "download failed: $WGET_URL"
    fi
    if ! printf '%s  %s\n' "$WGET_SHA256" "$tmp" | sha256sum -c - >/dev/null; then
        rm -f -- "$tmp"
        die "checksum mismatch for $WGET_URL"
    fi
    mv -f -- "$tmp" "$dest"
    chmod 755 "$dest"
    printf 'install.sh: installed %s\n' "$dest" >&2
}

copy_tree() {
    local dest
    dest=$PREFIX/cwa-sync
    if [ "$SRC" = "$dest" ]; then
        chmod 755 "$dest/cwa-sync" "$dest/install.sh" "$dest/uninstall.sh"
        return 0
    fi
    mkdir -p -- "$dest/lib" "$dest/systemd"
    cp -- "$SRC/cwa-sync" "$SRC/install.sh" "$SRC/uninstall.sh" \
        "$SRC/cwa-sync.conf.example" "$SRC/README.md" "$dest/"
    cp -- "$SRC/lib/util.sh" "$SRC/lib/http.sh" "$SRC/lib/sync.sh" "$SRC/lib/opds.awk" "$dest/lib/"
    cp -- "$SRC/systemd/cwa-sync.service" "$SRC/systemd/cwa-sync.timer" "$dest/systemd/"
    chmod 755 "$dest/cwa-sync" "$dest/install.sh" "$dest/uninstall.sh"
}

ensure_config() {
    local cfg
    cfg=$PREFIX/.config/cwa-sync.conf
    mkdir -p -- "$PREFIX/.config"
    if [ ! -f "$cfg" ]; then
        cp -- "$PREFIX/cwa-sync/cwa-sync.conf.example" "$cfg"
        chmod 600 "$cfg"
        printf 'install.sh: created %s\n' "$cfg" >&2
    else
        printf 'install.sh: keeping existing %s\n' "$cfg" >&2
    fi
}

ensure_profile() {
    local begin end
    begin="# cwa-sync PATH begin"
    end="# cwa-sync PATH end"
    if [ -f "$PROFILE" ] && grep -q -F -- "$begin" "$PROFILE"; then
        return 0
    fi
    mkdir -p -- "$(dirname -- "$PROFILE")"
    {
        printf '\n%s\n' "$begin"
        # The profile must keep a literal $PATH; the login shell expands it.
        # shellcheck disable=SC2016
        printf 'export PATH="%s:%s:$PATH"\n' "$PREFIX/.local/bin" "$PREFIX/cwa-sync"
        printf '%s\n' "$end"
    } >> "$PROFILE"
}

install_timer() {
    local unit_dir svc
    unit_dir=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
    mkdir -p -- "$unit_dir"
    svc=$unit_dir/cwa-sync.service
    sed "s#/home/root/cwa-sync/cwa-sync#$PREFIX/cwa-sync/cwa-sync#g" \
        "$PREFIX/cwa-sync/systemd/cwa-sync.service" > "$svc"
    cp -- "$PREFIX/cwa-sync/systemd/cwa-sync.timer" "$unit_dir/cwa-sync.timer"
    if [ "$unit_dir" = /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable --now cwa-sync.timer
        printf 'install.sh: enabled cwa-sync.timer\n' >&2
    else
        printf 'install.sh: wrote units in %s\n' "$unit_dir" >&2
        printf 'install.sh: enable later with: systemctl enable --now cwa-sync.timer\n' >&2
    fi
    printf 'install.sh: the timer lives on the rootfs and is removed by a firmware update. Re-run install.sh --timer afterwards.\n' >&2
    printf 'install.sh: the tablet does not run timers while it is suspended.\n' >&2
}

while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --prefix)
            if [ $# -lt 2 ]; then
                die "--prefix needs a directory"
            fi
            PREFIX=$2
            PROFILE=$PREFIX/.profile
            shift 2
            ;;
        --prefix=*)
            PREFIX=${1#--prefix=}
            PROFILE=$PREFIX/.profile
            shift
            ;;
        --timer)
            INSTALL_TIMER=1
            shift
            ;;
        --fetch-wget)
            FETCH_WGET=1
            shift
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

case $PREFIX in
    ""|/)
        die "refusing prefix '$PREFIX'"
        ;;
esac

copy_tree
ensure_config
mkdir -p -- "$PREFIX/.local/bin" "$PREFIX/plato-media"
ln -sfn "$PREFIX/cwa-sync/cwa-sync" "$PREFIX/.local/bin/cwa-sync"
ensure_profile

if [ "$FETCH_WGET" = 1 ] || ! have_tls_client; then
    install_static_wget
fi

if [ "$INSTALL_TIMER" = 1 ]; then
    install_timer
fi

cat <<EOF
Installed.

1. Edit $PREFIX/.config/cwa-sync.conf and set SERVER_URL, USERNAME and
   PASSWORD. The server is a calibre-web OPDS catalog (OPDS_PATH, default
   /opds), e.g. a crocodilestick/calibre-web-automated:latest container on
   port 8083. In calibre-web the user needs OPDS and download permission,
   and HTTP basic auth is used.
2. Dry run:
     $PREFIX/cwa-sync/cwa-sync --dry-run
3. Sync:
     $PREFIX/cwa-sync/cwa-sync
Books land in the DEST directory (default $PREFIX/plato-media) for Plato.

Optional timer (lost on firmware update): sh $PREFIX/cwa-sync/install.sh --timer
EOF
