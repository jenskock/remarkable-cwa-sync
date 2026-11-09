# OPDS walk and download. Sourced, not executed.
# shellcheck shell=sh

init_manifest() {
    MANIFEST=$STATE_DIR/manifest.tsv
    MANIFEST_NEW=$WORK/manifest.tsv
    if [ -f "$MANIFEST" ]; then
        cp "$MANIFEST" "$MANIFEST_NEW"
    else
        printf '%s\n' "# cwa-sync manifest v1" > "$MANIFEST_NEW"
    fi
}

parse_feed() {
    local src dst
    src=$1
    dst=$2
    LC_ALL=C awk -f "$BASE/lib/opds.awk" "$src" > "$dst"
}

normalize_url() {
    local u path query
    u=$1
    case $u in
        *\?*)
            path=${u%%\?*}
            query=${u#*\?}
            while :; do
                case $path in
                    */) path=${path%/} ;;
                    *) break ;;
                esac
            done
            printf '%s?%s' "$path" "$query"
            ;;
        *)
            while :; do
                case $u in
                    */) u=${u%/} ;;
                    *) break ;;
                esac
            done
            printf '%s' "$u"
            ;;
    esac
}

seen_url() {
    [ -f "$WORK/seen.urls" ] || return 1
    grep -F -x -q -- "$1" "$WORK/seen.urls"
}

mark_url() {
    printf '%s\n' "$1" >> "$WORK/seen.urls"
}

handle_nav() {
    local href title nav_author library series author_ctx abs tail
    local use_author use_series use_library
    href=$1
    title=$2
    nav_author=$3
    library=$4
    series=$5
    author_ctx=$6
    abs=$(resolve_against "$SERVER_URL/" "$href")
    if ! allows_redirect "$abs"; then
        log warn "skipping off-server link $(redact "$abs")"
        return 0
    fi
    tail=$(opds_tail "$abs")
    use_author=$author_ctx
    use_series=$series
    use_library=$library
    case $tail in
        external|download|download/*)
            log debug "skip $(classify_url "$abs") $(redact "$abs")"
            return 0
            ;;
        # calibre-web navigation feeds: the entry title of an author,
        # series or tag detail link is the author/series/tag name.
        author/*)
            if [ -n "$nav_author" ]; then
                use_author=$nav_author
            elif [ -n "$title" ]; then
                use_author=$title
            fi
            ;;
        series/*)
            if [ -n "$title" ]; then
                use_series=$title
            fi
            ;;
        category/*)
            if [ -n "$title" ]; then
                use_library=$title
            fi
            ;;
    esac
    crawl_feed "$abs" "$use_library" "$use_series" "$use_author" || return 1
}

record_book() {
    local key library series author title href mime remote
    key=$1
    library=$2
    series=$3
    author=$4
    title=$5
    href=$6
    mime=$7
    remote=$8
    printf '%s\n' "$key$US$library$US$series$US$author$US$title$US$href$US$mime$US$remote" >> "$WORK/books.raw"
}

crawl_feed() {
    local url library series author page norm body parsed next_here abs
    local line kind nav_title nav_author nav_href
    local b_id b_title b_author b_href b_type b_lname author_now key
    url=$1
    library=$2
    series=$3
    author=$4
    page=0
    while [ -n "$url" ]; do
        page=$((page + 1))
        if [ "$page" -gt 1000 ]; then
            log error "too many OPDS pages at $(redact "$url")"
            return 1
        fi
        norm=$(normalize_url "$url")
        if seen_url "$norm"; then
            log debug "already visited $(redact "$norm")"
            return 0
        fi
        mark_url "$norm"
        PARSE_SEQ=$((PARSE_SEQ + 1))
        body=$WORK/feed.$PARSE_SEQ
        parsed=$WORK/parsed.$PARSE_SEQ
        log debug "fetch feed $(redact "$url")"
        if ! http_fetch "$url" "$body" "" "" 120; then
            log error "failed to fetch feed $(redact "$url")"
            return 1
        fi
        case $HTTP_CODE in
            200) ;;
            401|403)
                log error "access denied (HTTP $HTTP_CODE). Check USERNAME/PASSWORD, and that the calibre-web user may use OPDS and download."
                return 1
                ;;
            *)
                log error "feed HTTP $HTTP_CODE for $(redact "$url")"
                return 1
                ;;
        esac
        if ! grep -q '<feed' "$body"; then
            log error "response is not an OPDS feed. If a reverse proxy returned a block page, set USER_AGENT in the config."
            return 1
        fi
        parse_feed "$body" "$parsed" || return 1
        if grep -q '<entry' "$body" && ! grep -q . "$parsed"; then
            log error "feed contains entries but none were recognised at $(redact "$url")"
            return 1
        fi
        next_here=""
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            IFS=$US
            # shellcheck disable=SC2086
            set -- $line
            IFS=$OIFS
            kind=${1:-}
            case $kind in
                NEXT)
                    next_here=${2:-}
                    ;;
                NAV)
                    nav_title=${3:-}
                    nav_author=${4:-}
                    nav_href=${5:-}
                    handle_nav "$nav_href" "$nav_title" "$nav_author" "$library" "$series" "$author" || return 1
                    ;;
                BOOK)
                    b_id=${2:-}
                    b_title=${3:-}
                    b_author=${4:-}
                    b_href=${5:-}
                    b_type=${6:-}
                    b_lname=${7:-}
                    author_now=$b_author
                    if [ -z "$author_now" ]; then
                        author_now=$author
                    fi
                    key=$(book_key "$b_href" "$b_id")
                    record_book "$key" "$library" "$series" "$author_now" "$b_title" "$b_href" "$b_type" "$b_lname"
                    ;;
                *)
                    log debug "ignoring feed record $kind"
                    ;;
            esac
        done < "$parsed"
        if [ -z "$next_here" ]; then
            break
        fi
        abs=$(resolve_against "$url" "$next_here")
        if [ "$(url_path "$url")" != "$(url_path "$abs")" ]; then
            log error "pagination link left the feed: $(redact "$abs")"
            return 1
        fi
        if ! allows_redirect "$abs"; then
            log error "refusing pagination URL $(redact "$abs")"
            return 1
        fi
        url=$abs
    done
    return 0
}

crawl() {
    local start
    start=$(printf '%s%s' "$SERVER_URL" "$OPDS_PATH")
    : > "$WORK/books.raw"
    : > "$WORK/seen.urls"
    if ! crawl_feed "$start" "" "" ""; then
        CRAWL_OK=0
        export CRAWL_OK
        return 1
    fi
    CRAWL_OK=1
    export CRAWL_OK
    return 0
}

dedupe_books() {
    if [ ! -s "$WORK/books.raw" ]; then
        : > "$WORK/books"
        return 0
    fi
    # One record per book key. The same book shows up in several catalogue
    # sections (books, authors, series, tags) with different context, so
    # keep the first record and fill still-empty fields (library, series)
    # from later records.
    BOOK_US=$US LC_ALL=C awk '
        BEGIN { FS = ENVIRON["BOOK_US"]; OFS = FS }
        {
            k = $1
            if (!(k in seen)) {
                n++
                order[n] = k
                seen[k] = 1
                for (j = 1; j <= NF; j++) f[k, j] = $j
            } else {
                for (j = 1; j <= NF; j++) {
                    if (f[k, j] == "" && $j != "") f[k, j] = $j
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                out = f[k, 1]
                for (j = 2; j <= 8; j++) out = out FS f[k, j]
                print out
            }
        }
    ' "$WORK/books.raw" > "$WORK/books"
}

manifest_placeholder() {
    if [ -n "$1" ]; then
        printf '%s' "$1"
    else
        printf '%s' "-"
    fi
}

lookup_manifest() {
    local want mline
    want=$1
    MAN_ETAG=""
    MAN_LM=""
    MAN_SIZE=""
    MAN_REL=""
    [ -f "$MANIFEST_NEW" ] || return 1
    while IFS= read -r mline || [ -n "$mline" ]; do
        case $mline in
            ""|\#*) continue ;;
        esac
        IFS=$(printf '\t')
        # shellcheck disable=SC2086
        set -- $mline
        IFS=$OIFS
        if [ "${1:-}" = "$want" ]; then
            MAN_ETAG=${2:-}
            MAN_LM=${3:-}
            MAN_SIZE=${4:-}
            MAN_REL=${5:-}
            if [ "$MAN_ETAG" = "-" ]; then
                MAN_ETAG=""
            fi
            if [ "$MAN_LM" = "-" ]; then
                MAN_LM=""
            fi
            return 0
        fi
    done < "$MANIFEST_NEW"
    return 1
}

manifest_upsert() {
    local key etag lm size rel tmpf mline found
    key=$1
    etag=$(manifest_placeholder "$2")
    lm=$(manifest_placeholder "$3")
    size=$4
    rel=$5
    tmpf=$WORK/manifest.upsert
    : > "$tmpf"
    found=0
    while IFS= read -r mline || [ -n "$mline" ]; do
        case $mline in
            ""|\#*)
                printf '%s\n' "$mline" >> "$tmpf"
                continue
                ;;
        esac
        IFS=$(printf '\t')
        # shellcheck disable=SC2086
        set -- $mline
        IFS=$OIFS
        if [ "${1:-}" = "$key" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$etag" "$lm" "$size" "$rel" >> "$tmpf"
            found=1
        else
            printf '%s\n' "$mline" >> "$tmpf"
        fi
    done < "$MANIFEST_NEW"
    if [ "$found" = 0 ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$etag" "$lm" "$size" "$rel" >> "$tmpf"
    fi
    mv -f "$tmpf" "$MANIFEST_NEW"
}

remove_empty_dirs() {
    local dir
    dir=$1
    while [ -n "$dir" ] && [ "$dir" != "$DEST" ] && [ "$dir" != "/" ]; do
        rmdir "$dir" 2>/dev/null || return 0
        dir=$(dirname -- "$dir")
    done
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

download_one() {
    local key library series author title href mime remote
    local rel final tmp etag_send lm_send size
    key=$1
    library=$2
    series=$3
    author=$4
    title=$5
    href=$6
    mime=$7
    remote=$8
    if [ -z "$href" ]; then
        log error "book $key has no download link"
        errors=$((errors + 1))
        return 0
    fi
    href=$(resolve_against "$SERVER_URL/" "$href")
    if ! allows_redirect "$href"; then
        log error "refusing download URL $(redact "$href")"
        errors=$((errors + 1))
        return 0
    fi
    remote=$(urldecode "$remote")
    case ${remote##*/} in
        *.*) ;;
        # calibre-web sets the acquisition link title to the format ("EPUB"),
        # not a filename; fall back to the entry title plus the mime extension.
        *) remote="" ;;
    esac
    remote=$(safe_filename "$remote" "$title" "$mime")
    rel=$(build_rel "$library" "$series" "$author" "$remote")
    rel=$(reserve_rel "$rel" "$key")
    final=$DEST/$rel

    if [ "$DRY" = 1 ]; then
        if [ "$FORCE" != 1 ] && lookup_manifest "$key" && [ -n "$MAN_REL" ] && [ -f "$DEST/$MAN_REL" ]; then
            log info "would skip $rel"
            unchanged=$((unchanged + 1))
        else
            log info "would download $rel"
            downloaded=$((downloaded + 1))
        fi
        return 0
    fi

    etag_send=""
    lm_send=""
    MAN_REL=""
    MAN_SIZE=""
    if [ "$FORCE" != 1 ] && lookup_manifest "$key"; then
        if [ -f "$final" ] || { [ -n "$MAN_REL" ] && [ -f "$DEST/$MAN_REL" ]; }; then
            etag_send=$MAN_ETAG
            lm_send=$MAN_LM
        fi
    fi

    mkdir -p -- "$(dirname -- "$final")"
    tmp=$final.partial.$$
    if ! http_fetch "$href" "$tmp" "$etag_send" "$lm_send" 7200; then
        rm -f -- "$tmp"
        log error "download failed for $rel"
        errors=$((errors + 1))
        return 0
    fi
    case $HTTP_CODE in
        304)
            rm -f -- "$tmp"
            if [ ! -f "$final" ] && { [ -z "$MAN_REL" ] || [ ! -f "$DEST/$MAN_REL" ]; }; then
                log error "server returned 304 but $rel is not on disk"
                errors=$((errors + 1))
                return 0
            fi
            if [ -n "$MAN_REL" ] && [ "$MAN_REL" != "$rel" ] && [ -f "$DEST/$MAN_REL" ]; then
                mkdir -p -- "$(dirname -- "$final")"
                mv -f -- "$DEST/$MAN_REL" "$final"
                log info "rename $MAN_REL -> $rel"
                remove_empty_dirs "$(dirname -- "$DEST/$MAN_REL")"
            fi
            if [ -z "$HTTP_ETAG" ]; then
                HTTP_ETAG=$etag_send
            fi
            if [ -z "$HTTP_LAST_MOD" ]; then
                HTTP_LAST_MOD=$lm_send
            fi
            if [ -z "$HTTP_LENGTH" ]; then
                if [ -f "$final" ]; then
                    HTTP_LENGTH=$(file_size "$final")
                else
                    HTTP_LENGTH=$MAN_SIZE
                fi
            fi
            log info "unchanged $rel"
            unchanged=$((unchanged + 1))
            manifest_upsert "$key" "$HTTP_ETAG" "$HTTP_LAST_MOD" "$HTTP_LENGTH" "$rel"
            return 0
            ;;
        200) ;;
        401|403)
            rm -f -- "$tmp"
            log error "download denied (HTTP $HTTP_CODE) for $rel. Enable download permission for this user."
            errors=$((errors + 1))
            return 0
            ;;
        *)
            rm -f -- "$tmp"
            log error "download HTTP $HTTP_CODE for $rel"
            errors=$((errors + 1))
            return 0
            ;;
    esac
    if [ ! -s "$tmp" ]; then
        rm -f -- "$tmp"
        log error "empty file for $rel"
        errors=$((errors + 1))
        return 0
    fi
    size=$(file_size "$tmp")
    if [ -n "$HTTP_LENGTH" ] && [ "$HTTP_LENGTH" != "$size" ]; then
        rm -f -- "$tmp"
        log error "size mismatch for $rel (got $size, content-length $HTTP_LENGTH)"
        errors=$((errors + 1))
        return 0
    fi
    if [ -f "$final" ] && command -v cmp >/dev/null 2>&1 && cmp -s "$tmp" "$final"; then
        rm -f -- "$tmp"
        log info "unchanged $rel"
        unchanged=$((unchanged + 1))
    else
        mv -f -- "$tmp" "$final"
        chmod 644 "$final" || true
        log info "download $rel"
        downloaded=$((downloaded + 1))
    fi
    if [ -n "$MAN_REL" ] && [ "$MAN_REL" != "$rel" ] && [ -f "$DEST/$MAN_REL" ]; then
        rm -f -- "$DEST/$MAN_REL"
        remove_empty_dirs "$(dirname -- "$DEST/$MAN_REL")"
    fi
    if [ -z "$HTTP_LENGTH" ]; then
        HTTP_LENGTH=$size
    fi
    manifest_upsert "$key" "$HTTP_ETAG" "$HTTP_LAST_MOD" "$HTTP_LENGTH" "$rel"
    return 0
}

download_all() {
    local line
    [ -f "$WORK/books" ] || return 0
    : > "$WORK/used"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        IFS=$US
        # shellcheck disable=SC2086
        set -- $line
        IFS=$OIFS
        download_one "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" || true
    done < "$WORK/books"
}

prune() {
    local mline key rel path newm line
    newm=$WORK/manifest.pruned
    printf '%s\n' "# cwa-sync manifest v1" > "$newm"
    : > "$WORK/catalog.keys"
    if [ -f "$WORK/books" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            IFS=$US
            # shellcheck disable=SC2086
            set -- $line
            IFS=$OIFS
            printf '%s\n' "${1:-}" >> "$WORK/catalog.keys"
        done < "$WORK/books"
    fi
    while IFS= read -r mline || [ -n "$mline" ]; do
        case $mline in
            ""|\#*) continue ;;
        esac
        IFS=$(printf '\t')
        # shellcheck disable=SC2086
        set -- $mline
        IFS=$OIFS
        key=${1:-}
        rel=${5:-}
        if [ -z "$key" ]; then
            continue
        fi
        if grep -F -x -q -- "$key" "$WORK/catalog.keys"; then
            printf '%s\n' "$mline" >> "$newm"
            continue
        fi
        case $rel in
            ""|/*|../*|*/..|*/../*)
                log warn "not deleting unusual path for $key"
                printf '%s\n' "$mline" >> "$newm"
                continue
                ;;
        esac
        path=$DEST/$rel
        case $path in
            "$DEST"/*) ;;
            *)
                log warn "not deleting $path"
                printf '%s\n' "$mline" >> "$newm"
                continue
                ;;
        esac
        if [ "$DRY" = 1 ]; then
            log info "would delete $rel"
        else
            if [ -e "$path" ] || [ -L "$path" ]; then
                rm -f -- "$path"
            fi
            log info "delete $rel"
            remove_empty_dirs "$(dirname -- "$path")"
        fi
        deleted=$((deleted + 1))
    done < "$MANIFEST_NEW"
    if [ "$DRY" != 1 ]; then
        mv -f "$newm" "$MANIFEST_NEW"
    fi
}

commit_manifest() {
    local tmp
    if [ "$DRY" = 1 ]; then
        return 0
    fi
    tmp=$STATE_DIR/manifest.tsv.tmp
    cp "$MANIFEST_NEW" "$tmp"
    mv -f "$tmp" "$STATE_DIR/manifest.tsv"
    chmod 600 "$STATE_DIR/manifest.tsv" || true
}
