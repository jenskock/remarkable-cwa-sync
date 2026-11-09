# Parse a calibre-web OPDS 1.2 Atom feed into records separated by ASCII 0x1F.
# Works with BusyBox awk and mawk. Feed bytes are treated as opaque (LC_ALL=C).
#
# Output lines:
#   NEXT <US> href
#   NAV  <US> id <US> title <US> author <US> href
#   BOOK <US> id <US> title <US> author <US> href <US> type <US> link-title
#
# Acquisition is any rel under http://opds-spec.org/acquisition except
# sample/preview/borrow/buy/subscribe. calibre-web uses
# http://opds-spec.org/acquisition and emits one link per book format.
# Subsection rels are navigation.
# Pagination is the feed-level rel="next" link (?offset=N).

function utf8(cp) {
    if (cp < 32) {
        if (cp == 9 || cp == 10 || cp == 13) return sprintf("%c", cp)
        return ""
    }
    if (cp < 128) return sprintf("%c", cp)
    if (cp < 2048) {
        return sprintf("%c%c", 192 + int(cp / 64), 128 + (cp % 64))
    }
    if (cp < 65536) {
        return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int((cp / 64) % 64), 128 + (cp % 64))
    }
    if (cp > 1114111) return ""
    return sprintf("%c%c%c%c",
        240 + int(cp / 262144),
        128 + int((cp / 4096) % 64),
        128 + int((cp / 64) % 64),
        128 + (cp % 64))
}

function hexval(h,    i, n, d, c) {
    n = 0
    for (i = 1; i <= length(h); i++) {
        c = toupper(substr(h, i, 1))
        d = index("0123456789ABCDEF", c)
        if (d == 0) return -1
        n = n * 16 + d - 1
    }
    return n
}

function replace(s, a, b,    out, i, n) {
    out = ""
    n = length(a)
    while ((i = index(s, a)) > 0) {
        out = out substr(s, 1, i - 1) b
        s = substr(s, i + n)
    }
    return out s
}

function xmldec(s,    ent, cp, hex) {
    if (s == "") return ""
    s = replace(s, "&lt;", "<")
    s = replace(s, "&gt;", ">")
    s = replace(s, "&quot;", "\"")
    s = replace(s, "&apos;", "'")
    while (match(s, /&#[0-9][0-9]*;/)) {
        ent = substr(s, RSTART, RLENGTH)
        cp = substr(ent, 3, length(ent) - 3) + 0
        s = substr(s, 1, RSTART - 1) utf8(cp) substr(s, RSTART + RLENGTH)
    }
    while (match(s, /&#[xX][0-9A-Fa-f][0-9A-Fa-f]*;/)) {
        ent = substr(s, RSTART, RLENGTH)
        hex = substr(ent, 4, length(ent) - 4)
        s = substr(s, 1, RSTART - 1) utf8(hexval(hex)) substr(s, RSTART + RLENGTH)
    }
    s = replace(s, "&amp;", "&")
    return s
}

function trim(s) {
    gsub(/\r/, "", s)
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
}

function oneline(s) {
    gsub(US, " ", s)
    gsub(/\n/, " ", s)
    gsub(/\r/, " ", s)
    gsub(/\t/, " ", s)
    return s
}

function attr(s, key,    search, pos, start, q, val, end) {
    search = key "="
    pos = 1
    while (pos <= length(s)) {
        start = index(substr(s, pos), search)
        if (start == 0) return ""
        start = pos + start - 1
        if (start == 1 || substr(s, start - 1, 1) ~ /[[:space:]]/) {
            q = substr(s, start + length(search), 1)
            if (q == "\"" || q == "'") {
                val = substr(s, start + length(search) + 1)
                end = index(val, q)
                if (end > 0) return substr(val, 1, end - 1)
            }
        }
        pos = start + length(search)
    }
    return ""
}

function is_acq(rel) {
    if (index(rel, "opds-spec.org/acquisition") == 0) return 0
    if (index(rel, "sample") > 0) return 0
    if (index(rel, "preview") > 0) return 0
    if (index(rel, "/borrow") > 0) return 0
    if (index(rel, "/buy") > 0) return 0
    if (index(rel, "/subscribe") > 0) return 0
    return 1
}

function reset_entry() {
    eid = ""
    etitle = ""
    eauthor = ""
    in_author = 0
    acq_n = 0
    nav_href = ""
}

function flush_entry(    i) {
    if (!in_entry) return
    if (acq_n > 0) {
        for (i = 1; i <= acq_n; i++) {
            printf "BOOK%s%s%s%s%s%s%s%s%s%s%s%s\n", \
                US, oneline(eid), \
                US, oneline(etitle), \
                US, oneline(eauthor), \
                US, oneline(acq_href[i]), \
                US, oneline(acq_type[i]), \
                US, oneline(acq_title[i])
        }
    } else if (nav_href != "") {
        printf "NAV%s%s%s%s%s%s%s%s\n", \
            US, oneline(eid), \
            US, oneline(etitle), \
            US, oneline(eauthor), \
            US, oneline(nav_href)
    }
    in_entry = 0
}

BEGIN {
    RS = "<"
    US = sprintf("%c", 31)
    in_entry = 0
    in_author = 0
    acq_n = 0
}

{
    gt = index($0, ">")
    if (gt == 0) next
    tag = substr($0, 1, gt - 1)
    rest = substr($0, gt + 1)
    if (tag ~ /^[?!]/) next

    if (substr(tag, 1, 1) == "/") {
        name = substr(tag, 2)
        sub(/[[:space:]].*/, "", name)
        sub(/^[^:]+:/, "", name)
        if (name == "entry") flush_entry()
        else if (name == "author") in_author = 0
        next
    }

    sub(/\/[[:space:]]*$/, "", tag)
    name = tag
    sub(/[[:space:]].*/, "", name)
    sub(/^[^:]+:/, "", name)
    attrs = tag
    sub(/^[^[:space:]]+/, "", attrs)

    if (name == "entry") {
        flush_entry()
        reset_entry()
        in_entry = 1
        next
    }

    if (name == "link") {
        rel = xmldec(attr(attrs, "rel"))
        href = xmldec(attr(attrs, "href"))
        type = xmldec(attr(attrs, "type"))
        ltitle = xmldec(attr(attrs, "title"))
        if (href == "") next
        if (!in_entry) {
            if (rel == "next") printf "NEXT%s%s\n", US, oneline(href)
            next
        }
        if (is_acq(rel)) {
            acq_n++
            acq_href[acq_n] = href
            acq_type[acq_n] = type
            acq_title[acq_n] = ltitle
        } else if (rel == "subsection" && nav_href == "") {
            nav_href = href
        }
        next
    }

    if (!in_entry) next
    if (name == "author") {
        in_author = 1
        next
    }
    if (name == "name" && in_author) {
        nm = trim(xmldec(rest))
        if (nm != "") {
            if (eauthor == "") eauthor = nm
            else eauthor = eauthor ", " nm
        }
        next
    }
    if (name == "id") {
        eid = trim(xmldec(rest))
        next
    }
    if (name == "title") {
        etitle = trim(xmldec(rest))
        next
    }
}

END {
    flush_entry()
}
