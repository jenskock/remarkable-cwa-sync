# cwa-sync

Spiegelt die E-Books eines selbst gehosteten [calibre-web](https://github.com/janeczku/calibre-web)-Servers — zum Beispiel aus dem Docker-Image [`crocodilestick/calibre-web-automated:latest`](https://github.com/crocodilestick/Calibre-Web-Automated) — auf ein reMarkable 2, in das Verzeichnis, aus dem [Plato](https://github.com/baskerville/plato) liest.

Das Programm läuft auf dem Tablet (Firmware 3.28, BusyBox-`sh`, kein Paketmanager). Es spricht den OPDS-Katalog von calibre-web (`/opds`, HTTP-Basic-Auth mit Benutzername und Passwort), lädt epub, pdf, cbz und die übrigen Formate herunter und lässt Dateien liegen, die sich nicht geändert haben.

Firmware-Updates löschen das Root-Dateisystem. Alles, was bleiben soll, liegt deshalb unter `/home/root`.

## Server

Das Image `crocodilestick/calibre-web-automated:latest` lauscht standardmäßig auf Port 8083 (änderbar über `CWA_PORT_OVERRIDE` im Container), der OPDS-Katalog liegt unter `http://<host>:8083/opds`:

```sh
docker run -d --name calibre-web-automated \
  -p 8083:8083 \
  -v /srv/cwa/config:/config \
  -v /srv/cwa/library:/calibre-library \
  -v /srv/cwa/ingest:/cwa-book-ingest \
  crocodilestick/calibre-web-automated:latest
```

## Zugangsdaten

calibre-web nutzt für OPDS HTTP-Basic-Auth — Benutzername und Passwort des Web-Logins, nicht einen API-Schlüssel in der URL. Im Container ist der anonyme Zugriff abgeschaltet, es werden also immer Zugangsdaten gebraucht.

In calibre-web, für den Benutzer, dessen Bibliothek synchronisiert werden soll:

1. Admin-Bereich → Benutzer bearbeiten → dem Benutzer **OPDS** erlauben.
2. Dem Benutzer das Recht **Herunterladen** geben. Ohne dieses Recht antwortet `/opds/download/...` mit 401, und es kommt keine Datei an.
3. Benutzername und Passwort in die Konfiguration auf dem Tablet eintragen (`USERNAME`, `PASSWORD`).

Der Server muss nicht öffentlich erreichbar sein; ein Zugriff aus dem LAN genügt, solange das Tablet ihn erreicht.

Benutzername, Passwort und Server-URL stehen nur in der Konfiguration auf dem Tablet, nicht in diesem Repository.

## Installation

Das Tablet per USB anschließen. Die Netzwerkadresse ist in der Regel `10.11.99.1`, der Benutzer `root`. Das Passwort steht auf dem Gerät unter Settings → General → About (Copyrights and licenses).

Vom Rechner aus, im Verzeichnis dieses Repositories:

```sh
scp -r . root@10.11.99.1:/home/root/cwa-sync
ssh root@10.11.99.1 'sh /home/root/cwa-sync/install.sh'
```

Auf dem Tablet, wenn die Dateien schon unter `/home/root/cwa-sync` liegen:

```sh
sh /home/root/cwa-sync/install.sh
```

`install.sh` legt an:

| Pfad | Inhalt |
| --- | --- |
| `/home/root/cwa-sync/` | Skript, Bibliotheken, Beispielkonfiguration |
| `/home/root/.local/bin/cwa-sync` | Symlink |
| `/home/root/.config/cwa-sync.conf` | Konfiguration, Modus 600, wird nie überschrieben |
| `/home/root/plato-media/` | Zielverzeichnis für Plato |
| `/home/root/.profile` | PATH-Ergänzung zwischen zwei Markierungszeilen |

Danach die Konfiguration bearbeiten:

```sh
vi /home/root/.config/cwa-sync.conf
```

`SERVER_URL` auf den Container-Host mit Port (z. B. `http://192.168.1.10:8083`) setzen, dazu `USERNAME` und `PASSWORD` eintragen.

Wenn `cwa-sync` danach nicht im PATH liegt, einmal `source /home/root/.profile` ausführen oder das Programm über den vollen Pfad starten:

```sh
/home/root/cwa-sync/cwa-sync --dry-run
```

### HTTPS

Läuft calibre-web hinter einem Reverse Proxy mit HTTPS, braucht das Tablet einen TLS-fähigen Client. Das wget von BusyBox auf dem reMarkable spricht kein TLS. `install.sh` prüft, ob `curl` oder ein wget mit HTTPS vorhanden ist. Fehlt beides, lädt es das statische wget von Toltec über HTTP nach `/home/root/.local/bin/wget` und prüft die SHA-256-Summe, bevor es die Datei aktiviert. Dasselbe erzwingt `--fetch-wget`.

Manche Reverse Proxies blockieren einen nackten wget-User-Agent. Die Beispielkonfiguration setzt deshalb einen normalen Browser-Agenten. Steht in der Logdatei, die Antwort sei kein OPDS-Feed, den `USER_AGENT` in der Konfiguration setzen.

### Optionen von install.sh

```sh
sh install.sh [--prefix DIR] [--timer] [--fetch-wget]
```

`--prefix` ändert das Basisverzeichnis (Vorgabe `/home/root`). `--timer` installiert einen systemd-Timer, siehe unten.

## Konfiguration

Die Datei ist `KEY=VALUE` und wird nicht als Shell-Skript ausgeführt. Vorlage: `cwa-sync.conf.example`.

| Schlüssel | Bedeutung |
| --- | --- |
| `SERVER_URL` | Origin des calibre-web-Containers, ohne Schrägstrich am Ende, z. B. `http://192.168.1.10:8083`. Ein Unterpfad hinter einem Reverse Proxy ist erlaubt. |
| `OPDS_PATH` | Pfad des OPDS-Katalogs. Vorgabe `/opds`. |
| `USERNAME` | calibre-web-Benutzername für HTTP-Basic-Auth. |
| `PASSWORD` | Passwort des Benutzers. |
| `DEST` | Absolutes Zielverzeichnis. Vorgabe `/home/root/plato-media`. `/`, `/home` und `/home/root` werden abgelehnt. |
| `LAYOUT` | Ordnerstruktur, siehe unten. Vorgabe `author`. |
| `STATE_DIR` | Manifest und Sperre. Vorgabe `/home/root/.local/share/cwa-sync`. |
| `DELETE_MISSING` | `1`, damit verschwundene Bücher gelöscht werden. Vorgabe `0`. |
| `USER_AGENT` | HTTP-User-Agent. |
| `CA_CERT` | Optionales CA-Bundle, falls die Zertifikatsprüfung scheitert. |
| `INSECURE` | `1` nur zum Eingrenzen eines Zertifikatsproblems. |

`LAYOUT` ist eines von:

| Wert | Pfad |
| --- | --- |
| `flat` | `Titel.epub` |
| `series` | `Serie/Titel.epub` |
| `author` | `Autor/Titel.epub` |
| `author-series` | `Autor/Serie/Titel.epub` |
| `library` | `Tag/Titel.epub` |
| `library-series` | `Tag/Serie/Titel.epub` |
| `library-author-series` | `Tag/Autor/Serie/Titel.epub` |

calibre-web trägt den Autor an jeden Bucheintrag; Serie und Tag ergeben sich aus dem Katalogbereich, in dem das Buch zuerst gefunden wurde (`/opds/series/<id>`, `/opds/category/<id>`). Eine Ebene, die leer ist, wird ausgelassen (`author-series` ohne Serie wird zu `Autor/Titel.epub`).

Zeichen, die auf dem Dateisystem stören (`/ \ : * ? " < > |`), werden durch `-` ersetzt. Zwei Bücher mit demselben Dateinamen bekommen ein Suffix aus ihrem Katalogschlüssel, etwa `Die Verwandlung-dl-101-epub.epub`.

## Benutzung

```sh
cwa-sync --dry-run          # Katalog holen, nichts schreiben
cwa-sync                    # neue und geänderte Dateien laden
cwa-sync --delete           # zusätzlich lokal entfernen, was der Server nicht mehr führt
cwa-sync --force            # jede Datei neu laden, auch wenn sie unverändert wirkt
cwa-sync --verbose          # jede Katalog-Anfrage protokollieren
cwa-sync --config DATEI     # andere Konfiguration
```

`--dry-run` lädt die OPDS-Feeds, schreibt aber keine Bücher, löscht nichts und ändert das Manifest nicht. Die Zeilen lauten `would download`, `would skip` und, zusammen mit `--delete`, `would delete`.

Ein normaler Lauf lädt nur, was neu ist oder sich geändert hat (ETag und `If-Modified-Since`). Die Datei entsteht als `*.partial.<pid>` im Zielordner und wird erst danach umbenannt. Ist der Inhalt bytegleich, bleibt die vorhandene Datei.

`--delete` entfernt nur Dateien, die das Manifest kennt, die unter `DEST` liegen und die in diesem Lauf nicht mehr im Katalog standen. Der Lauf muss dafür den Katalog vollständig und ohne Fehler gelesen haben. Fremde Dateien in `DEST` bleiben stehen. Ohne `--delete` und mit `DELETE_MISSING=0` wird nichts gelöscht.

Zwei Läufe gleichzeitig sind gesperrt. Der zweite endet mit Status 3.

Exit-Status: `0` in Ordnung, `1` Fehler beim Sync, `2` Aufruf oder Konfiguration, `3` schon ein Lauf aktiv. Meldungen gehen nach stderr. Das Passwort wird in den Meldungen durch `***` ersetzt.

Was ankommt: alle Navigations-Abschnitte des Katalogs (Bücher, Neu, Autoren, Serien, Tags, Verlage, Sprachen, Formate — seitenweise über `?offset=`), darin jeder Bucheintrag mit jedem seiner Formate. calibre-web hängt die Download-Links (`/opds/download/<Buch-ID>/<Format>/`) direkt an den Bucheintrag; der Dateiname wird aus dem Buchtitel und dem MIME-Typ gebildet. Ein Buch mit mehreren Formaten landet mehrfach, etwa als `Titel.epub` und `Titel.pdf`. Duplikate über verschiedene Katalogabschnitte werden über den Download-Pfad erkannt und nur einmal geladen.

## Timer

Optional, und nach einem Firmware-Update wieder einzurichten, weil die Units unter `/etc` liegen:

```sh
sh /home/root/cwa-sync/install.sh --timer
```

Der Timer startet drei Minuten nach dem Boot und einmal am Tag (`OnCalendar=daily`, `Persistent=true`). Im Suspend laufen auf dem reMarkable keine Timer. Wer das Gerät meist schlafen lässt, startet den Sync von Hand, solange es wach ist.

## Deinstallation

```sh
sh /home/root/cwa-sync/uninstall.sh
```

Das entfernt Skript, Symlink, PATH-Block und die systemd-Units. Bücher, Konfiguration und Manifest bleiben.

```sh
sh /home/root/cwa-sync/uninstall.sh --purge-config --purge-state --remove-wget
```

`--purge-config` löscht die Konfiguration, `--purge-state` Manifest und Sperre, `--remove-wget` das statische wget. Die Bücher in `DEST` bleiben in jedem Fall.

## Tests

Auf einem Rechner mit `shellcheck`, `dash` oder `/bin/sh`, `python3`, `curl` und nach Möglichkeit `busybox`:

```sh
sh tests/run.sh
```

Das prüft die Skripte mit `shellcheck -s sh`, füttert einen lokalen calibre-web-artigen OPDS-Server (Basic-Auth, `/opds`, Download-Links, `?offset=`-Pagination) und wiederholt den Lauf unter BusyBox-`sh` mit BusyBox-`awk`. Abgedeckt sind unter anderem Dry-Run, inkrementeller Lauf, 304, `--force`, `--delete`, ein abgebrochener Katalog (dann wird nichts gelöscht), ein einzelner fehlgeschlagener Download, eine Weiterleitung auf einen anderen Host, falsche Zugangsdaten, die Sperre, Installation und Prüfsumme. HTTP wird mit curl, GNU wget und BusyBox-wget geprüft. Python läuft nur in diesem Test, nicht auf dem Tablet.
