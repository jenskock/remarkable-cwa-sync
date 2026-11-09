#!/bin/sh
# Exercise cwa-sync against a local calibre-web-style OPDS fixture.
# POSIX sh. The outer invocation also runs shellcheck and repeats the suite
# under BusyBox sh + BusyBox awk.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ "${1:-}" != "--inner" ]; then
    shellcheck -s sh \
        "$ROOT/cwa-sync" \
        "$ROOT/install.sh" \
        "$ROOT/uninstall.sh" \
        "$ROOT/lib/util.sh" \
        "$ROOT/lib/http.sh" \
        "$ROOT/lib/sync.sh" \
        "$ROOT/tests/run.sh"
    "$0" --inner
    awkdir=$(mktemp -d)
    cat > "$awkdir/awk" <<'EOF'
#!/bin/sh
exec busybox awk "$@"
EOF
    chmod 755 "$awkdir/awk"
    PATH="$awkdir:$PATH" CWA_TEST_SH="busybox sh" SKIP_INSTALL=1 SKIP_WGET=1 "$0" --inner
    rm -rf "$awkdir"
    exit 0
fi

if [ -z "${CWA_TEST_SH:-}" ]; then
    CWA_TEST_SH=/bin/sh
fi

WORK=$(mktemp -d)
ERR=$WORK/err
OUT=$WORK/out
CONTROL=$WORK/control
mkdir -p "$CONTROL"
: > "$CONTROL/stats.tsv"
printf '1\n' > "$CONTROL/version"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 "$ROOT/tests/mock_opds.py" "$PORT" "$CONTROL" >/dev/null 2>&1 &
MOCK_PID=$!

finish_tests() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" >/dev/null 2>&1 || true
        wait "$MOCK_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap finish_tests EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    printf '%s\n' '--- stdout ---' >&2
    cat "$OUT" >&2 2>/dev/null || true
    printf '%s\n' '--- stderr ---' >&2
    cat "$ERR" >&2 2>/dev/null || true
    exit 1
}

wait_health() {
    local i
    i=0
    while [ "$i" -lt 50 ]; do
        if curl -sf -o /dev/null "http://127.0.0.1:$PORT/health"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.05
    done
    fail "mock server did not start"
}

reset_control() {
    rm -f "$CONTROL/fail-books" "$CONTROL/fail-download-100" "$CONTROL/include-evil"
    printf '%s\n' "$1" > "$CONTROL/version"
}

hits() {
    local code part
    code=$1
    part=$2
    awk -F '\t' -v c="$code" -v p="$part" '
        $1 == c && index($2, p) > 0 { n++ }
        END { print n + 0 }
    ' "$CONTROL/stats.tsv"
}

CRED_B64=$(python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(b"test-user:test-pass").decode())')

sync_run() {
    local want allow_stdout rc
    want=$1
    shift
    allow_stdout=0
    if [ "${1:-}" = "--allow-stdout" ]; then
        allow_stdout=1
        shift
    fi
    set +e
    # shellcheck disable=SC2086
    env CWA_RETRY_SLEEP=0 $CWA_TEST_SH "$ROOT/cwa-sync" "$@" >"$OUT" 2>"$ERR"
    rc=$?
    set -e
    if [ "$rc" != "$want" ]; then
        fail "exit $rc, want $want"
    fi
    if [ "$allow_stdout" != 1 ] && [ -s "$OUT" ]; then
        fail "unexpected stdout"
    fi
    if grep -F -q -- "test-pass" "$ERR" || grep -F -q -- "$CRED_B64" "$ERR"; then
        fail "password leaked into the log"
    fi
}

write_cfg() {
    local cfg dest state layout
    cfg=$1
    dest=$2
    state=$3
    layout=$4
    cat > "$cfg" <<EOF
SERVER_URL=http://127.0.0.1:$PORT
OPDS_PATH=/opds
USERNAME=test-user
PASSWORD=test-pass
DEST=$dest
LAYOUT=$layout
STATE_DIR=$state
DELETE_MISSING=0
USER_AGENT=cwa-sync-test
INSECURE=0
EOF
}

tree_of() {
    python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
rows = []
if os.path.isdir(root):
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            rows.append(os.path.relpath(os.path.join(dirpath, name), root))
print("\n".join(rows))
PY
}

assert_tree() {
    local got
    got=$(tree_of "$1")
    if [ "$got" != "$2" ]; then
        printf 'tree mismatch\nwant:\n%s\ngot:\n%s\n' "$2" "$got" >&2
        fail "tree"
    fi
}

read_file() {
    python3 -c 'import pathlib,sys; sys.stdout.write(pathlib.Path(sys.argv[1]).read_bytes().decode())' "$1"
}

# --- parser and pure helpers ---
parser_out=$WORK/parsed
LC_ALL=C awk -f "$ROOT/lib/opds.awk" "$ROOT/tests/fixtures/feed.xml" > "$parser_out"
tr -d '\n\r' < "$ROOT/tests/fixtures/feed.xml" > "$WORK/mini.xml"
LC_ALL=C awk -f "$ROOT/lib/opds.awk" "$WORK/mini.xml" > "$WORK/parsed.mini"
if ! cmp -s "$parser_out" "$WORK/parsed.mini"; then
    fail "minified feed did not parse like the pretty feed"
fi
books=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="BOOK"{n++} END{print n+0}' "$parser_out")
navs=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="NAV"{n++} END{print n+0}' "$parser_out")
nexts=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="NEXT"{n++} END{print n+0}' "$parser_out")
[ "$books" = 2 ] || fail "parser book count $books (one per format)"
[ "$navs" = 1 ] || fail "parser nav count $navs"
[ "$nexts" = 1 ] || fail "parser next count $nexts"
author=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="BOOK" && $2=="urn:uuid:book-200"{print $4}' "$parser_out" | head -1)
python3 -c 'import sys; assert sys.argv[1]=="Jörg & Söhne", sys.argv[1]' "$author" || fail "author entity"
title=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="BOOK" && $2=="urn:uuid:book-200"{print $3}' "$parser_out" | head -1)
python3 -c 'import sys; assert sys.argv[1]=="Über den Berg", sys.argv[1]' "$title" || fail "title entity"
grep -q 'offset=2' "$parser_out" || fail "missing next href"
grep -q '/opds/download/200/epub/' "$parser_out" || fail "missing epub acquisition link"
grep -q '/opds/download/200/pdf/' "$parser_out" || fail "missing pdf acquisition link"
grep -q 'opds-spec.org/image' "$parser_out" && fail "image link was treated as a book"

# shellcheck disable=SC1091
. "$ROOT/lib/util.sh"
OPDS_PATH=/opds
SERVER_URL=http://127.0.0.1:9
san=$(sanitize_component 'a/b:c*?"<>|' 'x')
[ "$san" = "a-b-c------" ] || fail "sanitize got $san"
san=$(sanitize_component '  ..hidden  ' 'x')
[ "$san" = "hidden" ] || fail "sanitize dots got $san"
dec=$(urldecode '%43%20')
[ "$dec" = "C " ] || fail "urldecode got [$dec]"
b64=$(printf '%s' 'Aladdin:open sesame' | b64encode)
[ "$b64" = "QWxhZGRpbjpvcGVuIHNlc2FtZQ==" ] || fail "b64encode got $b64"
[ "$(classify_url "http://127.0.0.1:9/opds")" = "root" ] || fail "classify root"
[ "$(classify_url "http://127.0.0.1:9/opds/books")" = "nav" ] || fail "classify books"
[ "$(classify_url "http://127.0.0.1:9/opds/author/3")" = "nav" ] || fail "classify author"
[ "$(classify_url "http://127.0.0.1:9/opds/download/100/epub/")" = "download" ] || fail "classify download"
[ "$(classify_url "http://127.0.0.1:9/other")" = "skip" ] || fail "classify external"
[ "$(book_key "/opds/download/100/epub/" 100)" = "dl-100-epub" ] || fail "book key"
[ "$(book_key "/opds/download/100/epub/?x=1" 100)" = "dl-100-epub" ] || fail "book key with query"

if [ "${SKIP_INSTALL:-}" != 1 ]; then
    iprefix=$WORK/inst
    mkdir -p "$iprefix"
    SYSTEMD_UNIT_DIR=$WORK/units
    export SYSTEMD_UNIT_DIR
    mkdir -p "$SYSTEMD_UNIT_DIR"
    sh "$ROOT/install.sh" --prefix "$iprefix" --timer >/dev/null 2>&1
    sh "$ROOT/install.sh" --prefix "$iprefix" --timer >/dev/null 2>&1
    [ -x "$iprefix/cwa-sync/cwa-sync" ] || fail "install missing script"
    [ -L "$iprefix/.local/bin/cwa-sync" ] || fail "install missing symlink"
    [ -f "$iprefix/.config/cwa-sync.conf" ] || fail "install missing config"
    [ -f "$WORK/units/cwa-sync.timer" ] || fail "timer unit missing"
    grep -q "$iprefix/cwa-sync/cwa-sync" "$WORK/units/cwa-sync.service" || fail "service path"
    printf 'PASSWORD=keep-this\nSERVER_URL=http://127.0.0.1:8083\nOPDS_PATH=/opds\nDEST=/tmp/books\n' > "$iprefix/.config/cwa-sync.conf"
    sh "$ROOT/install.sh" --prefix "$iprefix" >/dev/null 2>&1
    grep -q 'keep-this' "$iprefix/.config/cwa-sync.conf" || fail "install rewrote config"
    markers=$(grep -c 'cwa-sync PATH begin' "$iprefix/.profile")
    [ "$markers" = 1 ] || fail "PATH block duplicated ($markers)"
    printf 'keep-book\n' > "$iprefix/plato-media/keep.txt"
    sh "$ROOT/uninstall.sh" --prefix "$iprefix" >/dev/null 2>&1
    [ ! -d "$iprefix/cwa-sync" ] || fail "uninstall left scripts"
    [ -f "$iprefix/plato-media/keep.txt" ] || fail "uninstall removed books"
    [ -f "$iprefix/.config/cwa-sync.conf" ] || fail "uninstall removed config"
    sh "$ROOT/install.sh" --prefix "$iprefix" >/dev/null 2>&1
    sh "$ROOT/uninstall.sh" --prefix "$iprefix" --purge-config --purge-state >/dev/null 2>&1
    [ ! -f "$iprefix/.config/cwa-sync.conf" ] || fail "purge-config kept config"
    www=$WORK/www
    mkdir -p "$www"
    printf 'not-a-real-wget\n' > "$www/wget.bin"
    good=$(sha256sum "$www/wget.bin" | awk '{print $1}')
    wport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    WWW=$www python3 - "$wport" <<'PY' >/dev/null 2>&1 &
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = os.environ["WWW"]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        data = open(os.path.join(root, "wget.bin"), "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        return
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
    wpid=$!
    i=0
    while [ "$i" -lt 50 ]; do
        if curl -sf -o /dev/null "http://127.0.0.1:$wport/wget.bin"; then
            break
        fi
        i=$((i + 1))
        sleep 0.05
    done
    wprefix=$WORK/wprefix
    mkdir -p "$wprefix"
    if CWA_FETCH_WGET_URL="http://127.0.0.1:$wport/wget.bin" \
        CWA_FETCH_WGET_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        sh "$ROOT/install.sh" --prefix "$wprefix" --fetch-wget >/dev/null 2>"$ERR"; then
        fail "bad checksum was accepted"
    fi
    [ ! -x "$wprefix/.local/bin/wget" ] || fail "bad wget was installed"
    CWA_FETCH_WGET_URL="http://127.0.0.1:$wport/wget.bin" \
        CWA_FETCH_WGET_SHA256="$good" \
        sh "$ROOT/install.sh" --prefix "$wprefix" --fetch-wget >/dev/null 2>&1
    [ -x "$wprefix/.local/bin/wget" ] || fail "static wget was not installed"
    got=$(sha256sum "$wprefix/.local/bin/wget" | awk '{print $1}')
    [ "$got" = "$good" ] || fail "installed wget checksum"
    kill "$wpid" >/dev/null 2>&1 || true
    wait "$wpid" >/dev/null 2>&1 || true
    unset SYSTEMD_UNIT_DIR
fi

wait_health
sync_run 0 --allow-stdout --help
sync_run 2 --config "$WORK/missing.conf"

EXPECTED=$(printf '%s\n' \
    "Ada Lovelace/Nested Comic.cbz" \
    "Franz Kafka/Die Verwandlung-dl-101-epub.epub" \
    "Franz Kafka/Die Verwandlung.epub" \
    "Jörg & Söhne/Über den Berg.epub")

cfg=$WORK/cwa-sync.conf
dest=$WORK/books
state=$WORK/state
write_cfg "$cfg" "$dest" "$state" author
reset_control 1

sync_run 0 --config "$cfg" --dry-run
[ ! -d "$dest" ] || [ -z "$(find "$dest" -type f -print)" ] || fail "dry-run wrote files"
grep -q 'would download' "$ERR" || fail "dry-run did not list downloads"
[ "$(hits 200 /opds/download/)" = 0 ] || fail "dry-run downloaded a book"

sync_run 0 --config "$cfg"
assert_tree "$dest" "$EXPECTED"
[ "$(read_file "$dest/Franz Kafka/Die Verwandlung.epub")" = "EPUB-100-v1" ] || fail "epub body"
[ "$(read_file "$dest/Franz Kafka/Die Verwandlung-dl-101-epub.epub")" = "EPUB-101-v1" ] || fail "collision body"
[ "$(read_file "$dest/Jörg & Söhne/Über den Berg.epub")" = "EPUB-200-v1" ] || fail "unicode body"
[ "$(read_file "$dest/Ada Lovelace/Nested Comic.cbz")" = "CBZ-12-v1" ] || fail "cbz body"
[ "$(hits 200 /opds/download/100/epub/)" = 1 ] || fail "duplicate book downloaded twice"
find "$dest" -name '*.partial.*' -print | grep -q . && fail "partial file left behind"
python3 -c 'import os,sys; sys.exit(0 if (os.stat(sys.argv[1]).st_mode & 0o777) == 0o600 else 1)' "$state/manifest.tsv" || fail "manifest mode"

before100=$(hits 200 /opds/download/100/epub/)
sync_run 0 --config "$cfg"
[ "$(hits 200 /opds/download/100/epub/)" = "$before100" ] || fail "unchanged book was downloaded again"
[ "$(hits 304 /opds/download/100/epub/)" -ge 1 ] || fail "no 304 for unchanged book"
grep -q 'unchanged ' "$ERR" || fail "missing unchanged log"
[ "$(read_file "$dest/Franz Kafka/Die Verwandlung.epub")" = "EPUB-100-v1" ] || fail "304 clobbered file"

sync_run 0 --config "$cfg" --force
[ "$(hits 200 /opds/download/100/epub/)" -gt "$before100" ] || fail "force did not redownload"

reset_control 2
sync_run 0 --config "$cfg"
[ "$(read_file "$dest/Jörg & Söhne/Über den Berg.epub")" = "EPUB-200-v2" ] || fail "changed book not updated"
[ -f "$dest/Ada Lovelace/Nested Comic.cbz" ] || fail "delete-off removed a book"

sync_run 0 --config "$cfg" --dry-run --delete
[ -f "$dest/Ada Lovelace/Nested Comic.cbz" ] || fail "dry-run delete removed a file"
grep -q 'would delete ' "$ERR" || fail "dry-run delete did not say so"

sync_run 0 --config "$cfg" --delete
[ ! -e "$dest/Ada Lovelace/Nested Comic.cbz" ] || fail "delete left the removed book"
[ ! -d "$dest/Ada Lovelace" ] || fail "empty author directory remained"
assert_tree "$dest" "$(printf '%s\n' \
    "Franz Kafka/Die Verwandlung-dl-101-epub.epub" \
    "Franz Kafka/Die Verwandlung.epub" \
    "Jörg & Söhne/Über den Berg.epub")"

# A failed catalogue must not delete tracked books.
safe=$WORK/safe-books
safe_state=$WORK/safe-state
write_cfg "$cfg" "$safe" "$safe_state" author
reset_control 1
sync_run 0 --config "$cfg"
reset_control 2
touch "$CONTROL/fail-books"
sync_run 1 --config "$cfg" --delete
[ -f "$safe/Ada Lovelace/Nested Comic.cbz" ] || fail "failed sync deleted a book"
grep -q 'not deleting' "$ERR" || fail "missing delete skip warning"
rm -f "$CONTROL/fail-books"

# One bad file must not leave a partial or wipe the rest.
bad=$WORK/bad-books
bad_state=$WORK/bad-state
write_cfg "$cfg" "$bad" "$bad_state" author
reset_control 1
touch "$CONTROL/fail-download-100"
sync_run 1 --config "$cfg"
[ ! -e "$bad/Franz Kafka/Die Verwandlung.epub" ] || fail "failed download was stored"
[ -f "$bad/Ada Lovelace/Nested Comic.cbz" ] || fail "other books skipped after an error"
find "$bad" -name '*.partial.*' -print | grep -q . && fail "partial left after error"
rm -f "$CONTROL/fail-download-100"

# Off-host redirect must not be followed.
evil=$WORK/evil-books
evil_state=$WORK/evil-state
write_cfg "$cfg" "$evil" "$evil_state" author
reset_control 1
touch "$CONTROL/include-evil"
sync_run 1 --config "$cfg"
grep -q 'refusing redirect' "$ERR" || fail "off-host redirect was not refused"
[ ! -e "$evil/Nobody/Stolen.epub" ] || fail "redirected book was saved"
rm -f "$CONTROL/include-evil"

# Series folders from the /opds/series section.
layout=$WORK/layout-books
layout_state=$WORK/layout-state
write_cfg "$cfg" "$layout" "$layout_state" series
reset_control 1
sync_run 0 --config "$cfg"
[ -f "$layout/Kafka Stories/Die Verwandlung.epub" ] || fail "series layout"
[ -f "$layout/Kafka Stories/Die Verwandlung-dl-101-epub.epub" ] || fail "series layout collision"
[ -f "$layout/Comics/Nested Comic.cbz" ] || fail "series layout comic"
[ -f "$layout/Über den Berg.epub" ] || fail "book without series should be flat"

# Wrong password.
badcred=$WORK/badcred.conf
write_cfg "$badcred" "$WORK/nowhere" "$WORK/nostate" author
sed 's/^PASSWORD=.*/PASSWORD=wrong-pass/' "$badcred" > "$WORK/badcred2.conf"
sync_run 1 --config "$WORK/badcred2.conf"
grep -q 'access denied' "$ERR" || fail "bad credentials were not reported"

# Overlapping run. Hold the lock the same way the client does: flock when
# available, otherwise the lockdir with a live pid.
lock_state=$state
mkdir -p "$lock_state"
holder=""
if command -v flock >/dev/null 2>&1; then
    (
        flock -n 9 || exit 1
        sleep 20
    ) 9>"$lock_state/cwa-sync.lock" &
    holder=$!
else
    mkdir "$lock_state/cwa-sync.lockdir"
    printf '%s\n' "$$" > "$lock_state/cwa-sync.lockdir/pid"
fi
sleep 0.2
write_cfg "$cfg" "$dest" "$lock_state" author
sync_run 3 --config "$cfg" --dry-run
if [ -n "$holder" ]; then
    kill "$holder" >/dev/null 2>&1 || true
    wait "$holder" >/dev/null 2>&1 || true
else
    rm -rf "$lock_state/cwa-sync.lockdir"
fi

if [ "${SKIP_WGET:-}" != 1 ]; then
    wdest=$WORK/wget-books
    wstate=$WORK/wget-state
    write_cfg "$cfg" "$wdest" "$wstate" author
    reset_control 1
    : > "$CONTROL/stats.tsv"
    CWA_HTTP_CLIENT=wget sync_run 0 --config "$cfg"
    assert_tree "$wdest" "$EXPECTED"
    CWA_HTTP_CLIENT=wget sync_run 0 --config "$cfg"
    [ "$(hits 304 /opds/download/100/epub/)" -ge 1 ] || fail "wget did not use conditional GET"
    [ "$(read_file "$wdest/Franz Kafka/Die Verwandlung.epub")" = "EPUB-100-v1" ] || fail "wget 304 clobber"

    wrap=$WORK/bin
    mkdir -p "$wrap"
    cat > "$wrap/wget" <<'EOF'
#!/bin/sh
exec busybox wget "$@"
EOF
    chmod 755 "$wrap/wget"
    bdest=$WORK/bb-books
    bstate=$WORK/bb-state
    write_cfg "$cfg" "$bdest" "$bstate" flat
    reset_control 1
    : > "$CONTROL/stats.tsv"
    CWA_HTTP_CLIENT=wget CWA_WGET="$wrap/wget" sync_run 0 --config "$cfg"
    [ -f "$bdest/Die Verwandlung.epub" ] || fail "busybox wget did not download"
    [ -f "$bdest/Nested Comic.cbz" ] || fail "busybox wget missed nested book"
    CWA_HTTP_CLIENT=wget CWA_WGET="$wrap/wget" sync_run 0 --config "$cfg"
    [ "$(hits 304 /opds/download/100/epub/)" -ge 1 ] || fail "busybox wget missed 304"
fi

printf 'ok (%s)\n' "$CWA_TEST_SH"
