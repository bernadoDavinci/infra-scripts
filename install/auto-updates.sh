#!/usr/bin/env bash
# Schaltet automatische Sicherheitsupdates (unattended-upgrades) ein.
#
# Aufruf (als root):
#   bash auto-updates.sh                 # nur Sicherheitsupdates, kein automatischer Neustart
#   bash auto-updates.sh reboot=03:30    # zusätzlich Neustart um 03:30, falls ein Update ihn verlangt
#   bash auto-updates.sh scope=stable    # Debian: auch Point-Release-Updates (Distro-Standard)
#   bash auto-updates.sh --disable       # automatische Updates wieder abschalten
#
# Unterstützt: Debian und Ubuntu mit apt und systemd (auch Proxmox-Nodes und LXC).
# Auf Proxmox-Nodes kommen nur Debian-Sicherheitsupdates; Proxmox-Pakete
# (pve-*, Kernel aus dem PVE-Repo) bleiben manuell.
# Erneut ausführen ist gefahrlos und übernimmt geänderte Parameter.
set -Eeuo pipefail

readonly AUTO_CONF="/etc/apt/apt.conf.d/20auto-upgrades"
readonly LOCAL_CONF="/etc/apt/apt.conf.d/52infra-unattended-upgrades"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

reboot_time=""; scope="security"; disable=0
for a in "$@"; do
    case "${a}" in
        reboot=*) reboot_time="${a#*=}" ;;
        scope=security|scope=stable) scope="${a#*=}" ;;
        --disable) disable=1 ;;
        -h|--help) echo "Parameter: reboot=HH:MM | scope=security|stable | --disable"; exit 0 ;;
        *) die "unbekannter Parameter: ${a} (erlaubt: reboot=HH:MM, scope=security|stable, --disable)" ;;
    esac
done
if [[ -n "${reboot_time}" ]]; then
    [[ "${reboot_time}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "reboot muss HH:MM sein, z. B. reboot=03:30"
fi

[[ ${EUID} -eq 0 ]] || die "als root ausführen (z. B. mit sudo)"
command -v apt-get >/dev/null 2>&1 || die "nur Debian/Ubuntu mit apt werden unterstützt"

# shellcheck source=/dev/null
. /etc/os-release
distro="${ID:-unknown}"

if [[ ${disable} -eq 1 ]]; then
    cat >"${AUTO_CONF}" <<'EOF'
// Verwaltet von infra-scripts/auto-updates.sh (--disable)
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOF
    rm -f "${LOCAL_CONF}"
    printf 'Automatische Updates auf %s abgeschaltet.\n' "$(hostname)"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y unattended-upgrades apt-listchanges

# 1) Periodische Läufe einschalten (täglich Paketlisten + Upgrade, wöchentlich aufräumen)
cat >"${AUTO_CONF}" <<'EOF'
// Verwaltet von infra-scripts/auto-updates.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# 2) Lokale Ergänzungen; überschreibt nichts in 50unattended-upgrades
{
    printf '// Verwaltet von infra-scripts/auto-updates.sh (scope=%s) – nicht von Hand ändern.\n' "${scope}"
    if [[ "${distro}" == "debian" && "${scope}" == "security" ]]; then
        # Debian aktiviert ab Werk auch Point-Release-Updates; hier nur Security.
        cat <<'EOF'
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
EOF
    fi
    # Ubuntu: der Distro-Standard ist bereits nur -security (+ ESM).
    cat <<'EOF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
    if [[ -n "${reboot_time}" ]]; then
        printf 'Unattended-Upgrade::Automatic-Reboot "true";\n'
        printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "${reboot_time}"
    else
        printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    fi
} >"${LOCAL_CONF}"
chmod 0644 "${AUTO_CONF}" "${LOCAL_CONF}"

# 3) Timer aktivieren (nur wenn systemd läuft, z. B. nicht in einem Build-Container)
if [[ -d /run/systemd/system ]]; then
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    systemctl enable unattended-upgrades.service >/dev/null 2>&1 || true
else
    printf 'Hinweis: systemd läuft nicht – Timer nicht aktiviert.\n'
fi

# 4) Prüfen: apt muss die Konfiguration lesen können, Trockenlauf zeigt die Quellen
apt-config dump >/dev/null || die "apt-Konfiguration fehlerhaft"
printf '\nTrockenlauf:\n'
unattended-upgrade --dry-run --debug 2>&1 \
    | grep -E '^(Allowed origins are|Packages that will be upgraded|No packages found)' \
    | sed -E 's/^/  /' | head -n 5 || true

printf '\nAutomatische Sicherheitsupdates auf %s aktiv (%s, scope=%s, Neustart: %s).\n' \
    "$(hostname)" "${distro}" "${scope}" "${reboot_time:-nein}"
printf 'Log: /var/log/unattended-upgrades/ und journalctl -t unattended-upgrade\n'
