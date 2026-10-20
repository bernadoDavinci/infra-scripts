# infra-scripts

Versionierte Installations- und Bootstrap-Skripte für Linux-Hosts im Homelab.

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
| [`install/alloy.sh`](install/alloy.sh) | Installiert und konfiguriert Grafana Alloy für systemd-Journald → Loki |
| [`install/hermes-diag.sh`](install/hermes-diag.sh) | Legt den Nur-Lese-Diagnoseuser `hermes` an (SSH-Key nur von Hermes, feste Befehlsliste: smartctl, zpool, dmesg …) |

## Eigenschaften

- bricht bei Fehlern ab (`set -Eeuo pipefail`)
- prüft Root-Rechte und `apt`
- installiert benötigte Abhängigkeiten
- kann wiederholt ausgeführt werden
- validiert die Alloy-Konfiguration vor dem Neustart
- verwendet keine im Repository gespeicherten Geheimnisse

## Lizenz

Private Homelab-Skriptsammlung; vorerst keine Lizenz für Weiterverwendung erteilt.
