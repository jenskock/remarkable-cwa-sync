# HTTP client for cwa-sync. Sourced, not executed.
# Prefers curl, then a TLS-capable wget. BusyBox wget on stock reMarkable
# firmware does not speak HTTPS; install.sh can drop a static wget in
# /home/root/.local/bin, which is checked before PATH.

# shellcheck shell=sh

https_capable_curl() {
    local bin out
    bin=$1
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    out=$("$bin" --version 2>&1 || true)
    printf '%s\n' "$out" | grep -E -q 'https|SSL|TLS'
}

https_capable_wget() {
    local bin out
    bin=$1
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    out=$("$bin" --version 2>&1 || true)
    if printf '%s\n' "$out" | grep -q '+https'; then
        return 0
    fi
    out=$("$bin" --help 2>&1 || true)
    printf '%s\n' "$out" | grep -q -i 'https'
}

need_tls() {
    case ${SERVER_URL:-} in
        https://*) return 0 ;;
        *) return 1 ;;
    esac
}

wget_detect_features() {
    local help
    help=$("$WGET_BIN" --help 2>&1 || true)
    WGET_MAX_REDIRECT=0
    WGET_HEADER=0
    WGET_USER_AGENT_LONG=0
    WGET_CA=0
    WGET_TIMEOUT_LONG=0
    WGET_READ_TIMEOUT=0
    if printf '%s\n' "$help" | grep -q -- '--max-redirect'; then
        WGET_MAX_REDIRECT=1
    fi
    if printf '%s\n' "$help" | grep -q -- '--header'; then
        WGET_HEADER=1
    fi
    if printf '%s\n' "$help" | grep -q -- '--user-agent'; then
        WGET_USER_AGENT_LONG=1
    fi
    if printf '%s\n' "$help" | grep -q -- '--ca-certificate'; then
        WGET_CA=1
    fi
    if printf '%s\n' "$help" | grep -q -- '--read-timeout'; then
        WGET_READ_TIMEOUT=1
    fi
    if printf '%s\n' "$help" | grep -q -- '--timeout='; then
        WGET_TIMEOUT_LONG=1
    fi
    if [ "$WGET_HEADER" != 1 ]; then
        log warn "this wget cannot send conditional headers; files are fully downloaded and compared locally"
    fi
}

pick_client() {
    local forced want_tls curl_bin wget_bin home_wget
    forced=${CWA_HTTP_CLIENT:-}
    if need_tls; then
        want_tls=1
    else
        want_tls=0
    fi
    curl_bin=${CWA_CURL:-}
    if [ -z "$curl_bin" ]; then
        curl_bin=$(command -v curl 2>/dev/null || true)
    fi
    home_wget=/home/root/.local/bin/wget
    wget_bin=${CWA_WGET:-}
    if [ -z "$wget_bin" ]; then
        if [ -x "$home_wget" ]; then
            wget_bin=$home_wget
        else
            wget_bin=$(command -v wget 2>/dev/null || true)
        fi
    fi

    if [ "$forced" = "curl" ]; then
        if [ -z "$curl_bin" ] || [ ! -x "$curl_bin" ]; then
            die "curl not found"
        fi
        if [ "$want_tls" = 1 ] && ! https_capable_curl "$curl_bin"; then
            die "curl has no TLS support"
        fi
        HTTP_KIND=curl
        CURL_BIN=$curl_bin
        log info "http client: curl ($CURL_BIN)"
        return 0
    fi
    if [ "$forced" = "wget" ]; then
        if [ -z "$wget_bin" ] || [ ! -x "$wget_bin" ]; then
            die "wget not found"
        fi
        if [ "$want_tls" = 1 ] && ! https_capable_wget "$wget_bin"; then
            die "wget has no TLS. Stock reMarkable BusyBox wget cannot open HTTPS. Run install.sh to fetch a static wget."
        fi
        HTTP_KIND=wget
        WGET_BIN=$wget_bin
        wget_detect_features
        log info "http client: wget ($WGET_BIN)"
        return 0
    fi
    if [ -n "$forced" ]; then
        usage_die "CWA_HTTP_CLIENT must be curl or wget"
    fi

    if [ -n "$curl_bin" ] && [ -x "$curl_bin" ]; then
        if [ "$want_tls" = 0 ] || https_capable_curl "$curl_bin"; then
            HTTP_KIND=curl
            CURL_BIN=$curl_bin
            log info "http client: curl ($CURL_BIN)"
            return 0
        fi
    fi
    if [ -x "$home_wget" ]; then
        if [ "$want_tls" = 0 ] || https_capable_wget "$home_wget"; then
            HTTP_KIND=wget
            WGET_BIN=$home_wget
            wget_detect_features
            log info "http client: wget ($WGET_BIN)"
            return 0
        fi
    fi
    if [ -n "$wget_bin" ] && [ -x "$wget_bin" ]; then
        if [ "$want_tls" = 0 ] || https_capable_wget "$wget_bin"; then
            HTTP_KIND=wget
            WGET_BIN=$wget_bin
            wget_detect_features
            log info "http client: wget ($WGET_BIN)"
            return 0
        fi
    fi
    die "no usable HTTP client for $SERVER_URL. Stock reMarkable OS ships BusyBox wget without HTTPS. Run install.sh (it can download a TLS wget over plain HTTP into /home/root/.local/bin), or place curl/wget on PATH."
}

header_value() {
    local name file
    name=$1
    file=$2
    [ -f "$file" ] || return 0
    LC_ALL=C awk -v name="$name" '
        BEGIN { want = tolower(name); val = "" }
        {
            line = $0
            sub(/\r$/, "", line)
            sep = index(line, ":")
            if (sep <= 1) next
            key = substr(line, 1, sep - 1)
            gsub(/^[[:space:]]+/, "", key)
            gsub(/[[:space:]]+$/, "", key)
            key = tolower(key)
            if (key == want) {
                val = substr(line, sep + 1)
                sub(/^[[:space:]]+/, "", val)
                sub(/ \[following\]$/, "", val)
            }
        }
        END { printf "%s", val }
    ' "$file"
}

http_code_from_file() {
    local file
    file=$1
    [ -f "$file" ] || return 0
    LC_ALL=C awk '
        BEGIN { code = "" }
        {
            line = $0
            sub(/\r$/, "", line)
            if (match(line, /HTTP\/[0-9.]+[ ]+[0-9][0-9][0-9]/)) {
                s = substr(line, RSTART, RLENGTH)
                n = split(s, a, /[ ]+/)
                code = a[n]
            }
        }
        END { printf "%s", code }
    ' "$file"
}

read_response_meta() {
    local file
    file=$1
    HTTP_ETAG=$(header_value "etag" "$file")
    HTTP_LAST_MOD=$(header_value "last-modified" "$file")
    HTTP_LENGTH=$(header_value "content-length" "$file")
    export HTTP_ETAG HTTP_LAST_MOD HTTP_LENGTH
}

audit_locations() {
    local file locf loc
    file=$1
    locf=$WORK/locations
    LC_ALL=C awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sep = index(line, ":")
            if (sep <= 1) next
            key = tolower(substr(line, 1, sep - 1))
            gsub(/^[[:space:]]+/, "", key)
            if (key == "location") {
                val = substr(line, sep + 1)
                sub(/^[[:space:]]+/, "", val)
                sub(/ \[following\]$/, "", val)
                print val
            }
        }
    ' "$file" > "$locf"
    while IFS= read -r loc || [ -n "$loc" ]; do
        [ -n "$loc" ] || continue
        case $loc in
            http://*|https://*)
                if ! allows_redirect "$loc"; then
                    log error "refusing redirect to $(redact "$loc")"
                    return 1
                fi
                ;;
        esac
    done < "$locf"
    return 0
}

curl_request() {
    local url dest etag lm max_time hdr errf code
    url=$1
    dest=$2
    etag=$3
    lm=$4
    max_time=$5
    hdr=$6
    errf=$WORK/curl.err
    : > "$errf"
    set -- -sS --connect-timeout 20 --max-time "$max_time" \
        -A "$USER_AGENT" -D "$hdr" -o "$dest" -w '%{http_code}'
    if [ -n "${AUTH_HEADER:-}" ]; then
        set -- "$@" -H "Authorization: $AUTH_HEADER"
    fi
    if [ -n "${CA_CERT:-}" ]; then
        set -- "$@" --cacert "$CA_CERT"
    fi
    if is_true "${INSECURE:-0}"; then
        set -- "$@" -k
    fi
    if [ -n "$etag" ]; then
        set -- "$@" -H "If-None-Match: $etag"
    fi
    if [ -n "$lm" ]; then
        set -- "$@" -H "If-Modified-Since: $lm"
    fi
    set -- "$@" -- "$url"
    code=$("$CURL_BIN" "$@" 2>"$errf") || {
        log error "curl failed: $(redact "$(cat "$errf")")"
        return 1
    }
    HTTP_CODE=$code
    read_response_meta "$hdr"
    return 0
}

wget_request() {
    local url dest etag lm max_time hdr
    url=$1
    dest=$2
    etag=$3
    lm=$4
    max_time=$5
    hdr=$6
    set -- -S -O "$dest" -o "$hdr"
    if [ "${WGET_MAX_REDIRECT:-0}" = 1 ]; then
        set -- "$@" --max-redirect=0
    fi
    if [ "${WGET_USER_AGENT_LONG:-0}" = 1 ]; then
        set -- "$@" --user-agent="$USER_AGENT"
    else
        set -- "$@" -U "$USER_AGENT"
    fi
    if [ "${WGET_READ_TIMEOUT:-0}" = 1 ]; then
        set -- "$@" --read-timeout="$max_time" --timeout=30
    elif [ "${WGET_TIMEOUT_LONG:-0}" = 1 ]; then
        set -- "$@" --timeout="$max_time"
    else
        set -- "$@" -T "$max_time"
    fi
    if [ -n "${CA_CERT:-}" ] && [ "${WGET_CA:-0}" = 1 ]; then
        set -- "$@" --ca-certificate="$CA_CERT"
    fi
    if is_true "${INSECURE:-0}"; then
        set -- "$@" --no-check-certificate
    fi
    if [ "${WGET_HEADER:-0}" = 1 ]; then
        if [ -n "${AUTH_HEADER:-}" ]; then
            set -- "$@" --header="Authorization: $AUTH_HEADER"
        fi
        if [ -n "$etag" ]; then
            set -- "$@" --header="If-None-Match: $etag"
        fi
        if [ -n "$lm" ]; then
            set -- "$@" --header="If-Modified-Since: $lm"
        fi
    elif [ -n "${AUTH_HEADER:-}" ]; then
        log warn "this wget cannot send the Authorization header; the server will likely answer 401"
    fi
    set -- "$@" "$url"
    "$WGET_BIN" "$@" || true
    HTTP_CODE=$(http_code_from_file "$hdr")
    if [ -z "$HTTP_CODE" ]; then
        log error "wget produced no HTTP status for $(redact "$url")"
        return 1
    fi
    read_response_meta "$hdr"
    return 0
}

http_request() {
    local url dest etag lm max_time hdr
    url=$1
    dest=$2
    etag=${3:-}
    lm=${4:-}
    max_time=${5:-120}
    hdr=$WORK/headers
    : > "$hdr"
    rm -f -- "$dest"
    HTTP_CODE=""
    HTTP_ETAG=""
    HTTP_LAST_MOD=""
    HTTP_LENGTH=""
    export HTTP_CODE HTTP_ETAG HTTP_LAST_MOD HTTP_LENGTH
    if [ "$HTTP_KIND" = "curl" ]; then
        curl_request "$url" "$dest" "$etag" "$lm" "$max_time" "$hdr" || return 1
    else
        wget_request "$url" "$dest" "$etag" "$lm" "$max_time" "$hdr" || return 1
    fi
    if ! audit_locations "$hdr"; then
        rm -f -- "$dest"
        return 1
    fi
    if [ "$HTTP_CODE" != "200" ]; then
        rm -f -- "$dest"
    fi
    # A 304 has no body. Content-Length here is not the file size.
    if [ "$HTTP_CODE" = "304" ]; then
        HTTP_LENGTH=""
        export HTTP_LENGTH
    fi
    return 0
}

retry_sleep() {
    local n
    n=$1
    if [ -n "${CWA_RETRY_SLEEP:-}" ]; then
        sleep "$CWA_RETRY_SLEEP"
    else
        sleep "$n"
    fi
}

http_fetch() {
    local url dest orig_etag orig_lm max_time attempt cur hop loc next ok etag lm
    url=$1
    dest=$2
    orig_etag=${3:-}
    orig_lm=${4:-}
    max_time=${5:-120}
    attempt=1
    while [ "$attempt" -le 3 ]; do
        etag=$orig_etag
        lm=$orig_lm
        cur=$url
        hop=0
        ok=1
        while [ "$hop" -lt 8 ]; do
            if ! http_request "$cur" "$dest" "$etag" "$lm" "$max_time"; then
                ok=0
                break
            fi
            case $HTTP_CODE in
                200|304)
                    return 0
                    ;;
                301|302|303|307|308)
                    loc=$(header_value "location" "$WORK/headers")
                    if [ -z "$loc" ]; then
                        log error "redirect without Location from $(redact "$cur")"
                        ok=0
                        break
                    fi
                    next=$(resolve_against "$cur" "$loc")
                    if ! allows_redirect "$next"; then
                        log error "refusing redirect to $(redact "$next")"
                        return 1
                    fi
                    etag=""
                    lm=""
                    cur=$next
                    hop=$((hop + 1))
                    ;;
                429|500|502|503|504)
                    log warn "HTTP $HTTP_CODE from $(redact "$cur") (attempt $attempt)"
                    ok=0
                    break
                    ;;
                *)
                    return 0
                    ;;
            esac
        done
        if [ "$ok" = 1 ]; then
            log error "too many redirects for $(redact "$url")"
            return 1
        fi
        case ${HTTP_CODE:-} in
            401|403|404)
                return 0
                ;;
        esac
        attempt=$((attempt + 1))
        if [ "$attempt" -le 3 ]; then
            retry_sleep "$attempt"
        fi
    done
    log error "giving up on $(redact "$url")"
    return 1
}
