#!/usr/bin/env python3
"""Local calibre-web-like OPDS server for tests. Not installed on the tablet.

Emulates the OPDS catalog of a calibre-web instance as run by the
crocodilestick/calibre-web-automated:latest container: HTTP basic auth on
/opds, subsection navigation feeds (books/authors/series/tags), one
acquisition link per format under /opds/download/<book_id>/<format>/, and
?offset=N pagination.
"""

import base64
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER = "test-user"
PASSWORD = "test-pass"
CRED = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode("utf-8")).decode("ascii")
CONTROL = ""
PORT = 0
LOCK = threading.Lock()


def flag(name):
    return os.path.exists(os.path.join(CONTROL, name))


def version():
    path = os.path.join(CONTROL, "version")
    try:
        with open(path, encoding="utf-8") as handle:
            return int(handle.read().strip() or "1")
    except (OSError, ValueError):
        return 1


def note(code, path, inm):
    with LOCK:
        with open(os.path.join(CONTROL, "stats.tsv"), "a", encoding="utf-8") as handle:
            handle.write(f"{code}\t{path}\t{inm}\n")


def xml(text):
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


# id, title, author, series, tag, formats [(format, mime)]
def all_books():
    books = [
        ("100", "Die Verwandlung", "Franz Kafka", "Kafka Stories", "Romane", [("epub", "application/epub+zip")]),
        ("101", "Die Verwandlung", "Franz Kafka", "Kafka Stories", "Romane", [("epub", "application/epub+zip")]),
        ("200", "Über den Berg", "Jörg & Söhne", None, "Romane", [("epub", "application/epub+zip")]),
        ("12", "Nested Comic", "Ada Lovelace", "Comics", "Comics", [("cbz", "application/x-cbz")]),
    ]
    if version() >= 2:
        books = [b for b in books if b[0] != "12"]
    return books


AUTHOR_IDS = {"Franz Kafka": "1", "Jörg & Söhne": "2", "Ada Lovelace": "3"}
TAG_IDS = {"Romane": "1", "Comics": "2"}
SERIES_IDS = {"Kafka Stories": "5", "Comics": "6"}


def feed(title, body, path, extra=""):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:dcterms="http://purl.org/dc/terms/">
  <id>urn:uuid:2853dacf-ed79-42f5-8e8a-a7bb3d1ae6a2</id>
  <updated>2026-01-01T00:00:00+00:00</updated>
  <link rel="self" href="{path}" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="up" href="/opds" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
{extra}  <link rel="search" href="/opds/osd" type="application/opensearchdescription+xml"/>
  <title>{xml(title)}</title>
  <author>
    <name>calibre-web</name>
    <uri>https://github.com/janeczku/calibre-web</uri>
  </author>
{body}
</feed>
"""


def nav(title, href):
    return f"""  <entry>
    <title>{xml(title)}</title>
    <id>http://127.0.0.1:{PORT}{href}</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="{href}"/>
  </entry>
"""


def book_entry(b):
    bid, title, author, series, tag, formats = b
    links = ""
    for fmt, mime in formats:
        links += (
            f'    <link rel="http://opds-spec.org/acquisition" href="/opds/download/{bid}/{fmt}/" '
            f'length="10" title="{fmt.upper()}" mtime="2026-01-01T00:00:00+00:00" type="{mime}"/>\n'
        )
    series_html = f"SERIES: {xml(series)} [1.00]<br/>" if series else ""
    return f"""  <entry>
    <title>{xml(title)}</title>
    <id>urn:uuid:book-{bid}</id>
    <updated>2026-01-01T00:00:00+00:00</updated>
    <author>
      <name>{xml(author)}</name>
    </author>
    <published>2026-01-01T00:00:00+00:00</published>
    <dcterms:language>eng</dcterms:language>
    <category scheme="http://www.bisg.org/standards/bisac_subject/index.html" term="{xml(tag)}" label="{xml(tag)}"/>
    <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">{series_html}</div></content>
    <link type="image/jpeg" href="/opds/cover/{bid}" rel="http://opds-spec.org/image"/>
{links}  </entry>
"""


def root_feed():
    # Section order matters for the sync tests: series first, so books are
    # first seen with a series context (dedupe keeps the first record).
    body = nav("Series", "/opds/series")
    body += nav("Tags", "/opds/category")
    body += nav("Authors", "/opds/author")
    body += nav("Books", "/opds/books")
    return feed("calibre-web", body, "/opds")


def series_index_feed():
    body = ""
    for name, sid in SERIES_IDS.items():
        body += nav(name, f"/opds/series/{sid}")
    return feed("Series", body, "/opds/series")


def series_feed(sid):
    name = next((n for n, i in SERIES_IDS.items() if i == sid), None)
    if name is None:
        return None
    body = "".join(book_entry(b) for b in all_books() if b[3] == name)
    return feed(name, body, f"/opds/series/{sid}")


def category_index_feed():
    body = "".join(nav(name, f"/opds/category/{tid}") for name, tid in TAG_IDS.items())
    if flag("include-evil"):
        body += nav("Evil", "/opds/category/99")
    return feed("Tags", body, "/opds/category")


def category_feed(tid):
    if tid == "99" and flag("include-evil"):
        return feed("Evil", book_entry(("999", "Stolen", "Nobody", None, "Evil", [("epub", "application/epub+zip")])), "/opds/category/99")
    name = next((n for n, i in TAG_IDS.items() if i == tid), None)
    if name is None:
        return None
    body = "".join(book_entry(b) for b in all_books() if b[4] == name)
    return feed(name, body, f"/opds/category/{tid}")


def author_index_feed():
    body = "".join(nav(name, f"/opds/author/{aid}") for name, aid in AUTHOR_IDS.items())
    return feed("Authors", body, "/opds/author")


def author_feed(aid):
    name = next((n for n, i in AUTHOR_IDS.items() if i == aid), None)
    if name is None:
        return None
    body = "".join(book_entry(b) for b in all_books() if b[2] == name)
    return feed(name, body, f"/opds/author/{aid}")


PAGE_SIZE = 2


def books_feed(offset):
    books = all_books()
    page = books[offset:offset + PAGE_SIZE]
    body = "".join(book_entry(b) for b in page)
    extra = ""
    if offset + PAGE_SIZE < len(books):
        extra = (
            f'  <link rel="next" title="Next" href="/opds/books?offset={offset + PAGE_SIZE}" '
            f'type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>\n'
        )
    return feed("Books", body, "/opds/books", extra)


def book_payload(book_id, fmt):
    if book_id == "100":
        return b"EPUB-100-v1", '"100-v1"', "application/epub+zip", "Die Verwandlung.epub"
    if book_id == "101":
        return b"EPUB-101-v1", '"101-v1"', "application/epub+zip", "Die Verwandlung.epub"
    if book_id == "200":
        if version() >= 2:
            return b"EPUB-200-v2", '"200-v2"', "application/epub+zip", "Über den Berg.epub"
        return b"EPUB-200-v1", '"200-v1"', "application/epub+zip", "Über den Berg.epub"
    if book_id == "12" and fmt == "cbz":
        return b"CBZ-12-v1", '"12-v1"', "application/x-cbz", "Nested.cbz"
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        inm = self.headers.get("If-None-Match") or ""
        code = self.dispatch(path, parsed.query, inm)
        note(code, path, inm)

    def dispatch(self, path, query, inm):
        if path == "/health":
            return self._bytes(200, b"ok", "text/plain")
        if not path.startswith("/opds"):
            return self._bytes(404, b"not found", "text/plain")
        if self.headers.get("Authorization") != CRED:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="calibre-web"')
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "9")
            self.end_headers()
            self.wfile.write(b"bad login")
            return 401
        rest = path[len("/opds"):]
        if rest.endswith("/") and rest != "/":
            rest = rest.rstrip("/")
        offset = int(parse_qs(query).get("offset", ["0"])[0])
        if rest in ("", "/"):
            return self._xml(root_feed())
        if rest == "/books":
            if flag("fail-books"):
                return self._bytes(500, b"feed failed", "text/plain")
            return self._xml(books_feed(offset))
        if rest == "/series":
            return self._xml(series_index_feed())
        m = re.match(r"^/series/([^/]+)$", rest)
        if m:
            body = series_feed(m.group(1))
            if body is None:
                return self._bytes(404, b"no series", "text/plain")
            return self._xml(body)
        if rest == "/category":
            return self._xml(category_index_feed())
        m = re.match(r"^/category/([^/]+)$", rest)
        if m:
            body = category_feed(m.group(1))
            if body is None:
                return self._bytes(404, b"no tag", "text/plain")
            return self._xml(body)
        if rest == "/author":
            return self._xml(author_index_feed())
        m = re.match(r"^/author/([^/]+)$", rest)
        if m:
            body = author_feed(m.group(1))
            if body is None:
                return self._bytes(404, b"no author", "text/plain")
            return self._xml(body)
        m = re.match(r"^/download/([^/]+)/([^/]+)/?$", rest)
        if m:
            book_id, fmt = m.group(1), m.group(2)
            if book_id == "999":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/stolen")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return 302
            if book_id == "100" and flag("fail-download-100"):
                return self._bytes(500, b"nope", "text/plain")
            payload = book_payload(book_id, fmt)
            if payload is None:
                return self._bytes(404, b"no file", "text/plain")
            data, etag, mime, filename = payload
            if inm == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return 304
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("ETag", etag)
            self.send_header("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.end_headers()
            self.wfile.write(data)
            return 200
        return self._bytes(404, b"no route", "text/plain")

    def _bytes(self, code, data, mime):
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        return code

    def _xml(self, text):
        return self._bytes(200, text.encode("utf-8"), "application/atom+xml; charset=utf-8")


def main():
    global CONTROL, PORT
    if len(sys.argv) != 3:
        print("usage: mock_opds.py PORT CONTROL_DIR", file=sys.stderr)
        return 2
    PORT = int(sys.argv[1])
    CONTROL = sys.argv[2]
    os.makedirs(CONTROL, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
