# infra-scripts

Versionierte Installations- und Bootstrap-Skripte für Linux-Hosts im Homelab.

## Neue VM einrichten (Menü)

```bash
curl -fsSL https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/setup.sh | sudo bash
```

`setup.sh` zeigt alle Skripte aus `install/` zur Auswahl (whiptail-Checkliste, ohne
whiptail ein Nummernmenü) und führt die gewählten nacheinander aus. Am Ende steht eine
Übersicht OK/FEHLER; ein fehlgeschlagenes Skript stoppt die übrigen nicht.

Ohne Menü, z. B. für Automatisierung:

```bash
curl -fsSL https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/setup.sh \
  | sudo bash -s -- auto-updates alloy      # oder: all
```

Aus einem Klon (`sudo bash setup.sh`) werden die lokalen Skripte verwendet, sonst lädt
`setup.sh` sie vom selben Ref (`REF=<tag|commit>` zum Festnageln).
Neues Skript: Datei nach `install/` legen und in der Tabelle `SCRIPTS` in `setup.sh` eintragen.

## Automatische Sicherheitsupdates

```bash
curl -fsSL https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/install/auto-updates.sh | sudo bash
```

Installiert `unattended-upgrades`, aktiviert tägliche Läufe und – auf Debian – beschränkt
die Quellen auf `Debian-Security` (Debian aktiviert ab Werk auch Point-Releases; Ubuntu
ist ab Werk schon nur `-security`). Kein automatischer Neustart, alte Kernel werden entfernt,
Log zusätzlich ins Journal (→ Alloy/Loki). Auf Proxmox-Nodes werden nur Debian-Pakete
aktualisiert, PVE-Pakete bleiben manuell.

| Parameter | Wirkung |
| --- | --- |
| `reboot=03:30` | Neustart zur angegebenen Uhrzeit, falls ein Update ihn verlangt |
| `scope=stable` | Debian: Distro-Standard (Security + Point-Releases) |
| `--disable` | Automatische Updates wieder abschalten |

Parameter beim Pipe-Aufruf mit `| sudo bash -s -- reboot=03:30` übergeben.

## Alloy installieren

Unterstützt werden aktuell Debian- und Ubuntu-Systeme mit `apt` und `systemd`.
Das Skript installiert Grafana Alloy, schreibt die Journal-to-Loki-Konfiguration,
validiert sie, aktiviert den Dienst und erzeugt abschließend einen Test-Logeintrag.

### Direkt ausführen

> [!WARNING]
> Ein über das Netzwerk geladenes Root-Skript sollte vor der Ausführung geprüft
> und in produktiven Umgebungen an einen Release-Tag oder Commit gebunden werden.

```bash
curl -fsSL https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/install/alloy.sh | sudo bash
```

Alternativ mit `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/install/alloy.sh | sudo bash
```

### Loki-Ziel überschreiben

Standardmäßig sendet Alloy an
`http://172.22.20.27:3100/loki/api/v1/push` mit Tenant `fake`.
Beide Werte können beim Aufruf überschrieben werden:

```bash
curl -fsSL https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/install/alloy.sh \
  | sudo LOKI_URL='http://loki.example:3100/loki/api/v1/push' LOKI_TENANT_ID='fake' bash
```

### Lokal prüfen und ausführen

```bash
curl -fsSLO https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/install/alloy.sh
bash -n alloy.sh
less alloy.sh
sudo bash alloy.sh
```

## Enthaltene Skripte

| Skript | Zweck |
| --- | --- |
| [`setup.sh`](setup.sh) | Auswahlmenü: führt die gewählten Skripte aus `install/` aus |
| [`install/auto-updates.sh`](install/auto-updates.sh) | Automatische Sicherheitsupdates per unattended-upgrades |
| [`install/alloy.sh`](install/alloy.sh) | Installiert und konfiguriert Grafana Alloy für systemd-Journald → Loki |
| [`install/hermes-diag.sh`](install/hermes-diag.sh) | Legt den Nur-Lese-Diagnoseuser `hermes` an: `hostType=pve` (inkl. smartctl/zpool) oder `hostType=vm`. Erneut ausführen übernimmt geänderte Befehlsliste. Ab v4 auch `systemctl-status <unit>`, `systemctl-failed` und `cloudflared-version`. |

## Eigenschaften

- bricht bei Fehlern ab (`set -Eeuo pipefail`)
- prüft Root-Rechte und `apt`
- installiert benötigte Abhängigkeiten
- kann wiederholt ausgeführt werden
- validiert die Alloy-Konfiguration vor dem Neustart
- verwendet keine im Repository gespeicherten Geheimnisse

## Lizenz

Private Homelab-Skriptsammlung; vorerst keine Lizenz für Weiterverwendung erteilt.
