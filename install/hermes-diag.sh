#!/usr/bin/env bash
# Legt einen eng begrenzten Diagnose-Zugang für Hermes an (nur lesend).
#
# - User "hermes" (änderbar über DIAG_USER): kein Passwort, Login nur per SSH-Key von der Hermes-VM.
# - Der Key ist per authorized_keys an einen Wrapper gebunden (command=...):
#   keine Shell, kein PTY, kein Port-/Agent-/X11-Forwarding.
# - Der Wrapper erlaubt nur eine feste Liste lesender Befehle. Befehle, die
#   root brauchen (smartctl, dmesg), laufen über sudo, aber nur über ein
#   root-eigenes Hilfsskript, das seine Argumente selbst streng prüft.
#
# Idempotent; erneut ausführen aktualisiert Key und Whitelist.
# Entfernen: sudo bash hermes-diag.sh --uninstall
set -Eeuo pipefail

readonly DIAG_USER="${DIAG_USER:-hermes}"
readonly HERMES_FROM="${HERMES_FROM:-172.22.20.25}"
readonly HERMES_PUBKEY="${HERMES_PUBKEY:-}"
readonly LIBEXEC="/usr/local/libexec/hermes-diag"
readonly SUDOERS="/etc/sudoers.d/hermes-diag"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "als root ausführen (z. B. mit sudo)"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "${SUDOERS}"
    rm -rf "${LIBEXEC}"
    if id "${DIAG_USER}" >/dev/null 2>&1 && [[ "$(getent passwd "${DIAG_USER}" | cut -d: -f5)" == "Hermes read-only diagnostics" ]]; then
        userdel -r "${DIAG_USER}" 2>/dev/null || userdel "${DIAG_USER}"
    fi
    printf '%s entfernt.\n' "${DIAG_USER}"
    exit 0
fi

[[ -n "${HERMES_PUBKEY}" ]] || die "HERMES_PUBKEY fehlt (öffentlicher SSH-Key der Hermes-VM)"
[[ "${HERMES_PUBKEY}" =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "HERMES_PUBKEY sieht nicht wie ein SSH-Public-Key aus"

command -v sudo >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq sudo; }
command -v smartctl >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq smartmontools; }

# 1) User ohne Passwort, ohne Gruppen mit Rechten
readonly MARKER="Hermes read-only diagnostics"
if id "${DIAG_USER}" >/dev/null 2>&1; then
    [[ "$(getent passwd "${DIAG_USER}" | cut -d: -f5)" == "${MARKER}" ]] \
        || die "User ${DIAG_USER} existiert bereits und wurde nicht von diesem Skript angelegt – Abbruch"
else
    useradd --system --create-home --shell /bin/sh --comment "${MARKER}" "${DIAG_USER}"
fi
passwd -l "${DIAG_USER}" >/dev/null
gpasswd -d "${DIAG_USER}" sudo >/dev/null 2>&1 || true

install -d -m 0755 -o root -g root "${LIBEXEC}"

# 2) Root-Hilfsskript: nur feste Befehle, Argumente strikt geprüft
cat >"${LIBEXEC}/root-helper" <<'EOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
dev_ok() { [[ "$1" =~ ^(nvme[0-9]+n[0-9]+|nvme[0-9]+|sd[a-z]{1,2})$ ]] && [[ -b "/dev/$1" || -c "/dev/$1" ]]; }
case "${1:-}" in
    smart)       dev_ok "${2:-}" || { echo "ungültiges Gerät" >&2; exit 2; }
                 smartctl -x "/dev/$2" || true ;;          # Exitcode != 0 bei Warnungen ist normal
    smart-scan)  smartctl --scan ;;
    nvme-log)    dev_ok "${2:-}" || { echo "ungültiges Gerät" >&2; exit 2; }
                 command -v nvme >/dev/null && nvme smart-log "/dev/$2" || echo "nvme-cli nicht installiert" ;;
    dmesg)       dmesg --ctime --level=err,warn,crit,alert,emerg | tail -n 500 ;;
    journal-kernel) [[ "${2:-}" =~ ^[0-9]{1,3}(h|d)$ ]] || { echo "Zeitraum z. B. 24h oder 7d" >&2; exit 2; }
                 journalctl -k --no-pager -p warning --since "-$2" | tail -n 1000 ;;
    *)           echo "nicht erlaubt" >&2; exit 2 ;;
esac
EOF
chown root:root "${LIBEXEC}/root-helper"; chmod 0755 "${LIBEXEC}/root-helper"

# 3) SSH-Wrapper: einzige Einstiegsstelle (forced command)
cat >"${LIBEXEC}/ssh-wrapper" <<EOF
#!/bin/bash
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
H=${LIBEXEC}/root-helper
read -r -a a <<<"\${SSH_ORIGINAL_COMMAND:-help}"
since_ok() { [[ "\${1:-}" =~ ^[0-9]{1,3}(h|d)\$ ]]; }
case "\${a[0]:-help}" in
    help)        echo "Erlaubt: smart <dev> | smart-scan | nvme-log <dev> | dmesg | journal-kernel <Nh|Nd> | zpool-status | zpool-list | sensors | lsblk | uptime | pveversion | free | df" ;;
    smart|nvme-log) [[ \${#a[@]} -eq 2 ]] || exit 2; sudo -n "\$H" "\${a[0]}" "\${a[1]}" ;;
    smart-scan|dmesg) [[ \${#a[@]} -eq 1 ]] || exit 2; sudo -n "\$H" "\${a[0]}" ;;
    journal-kernel) since_ok "\${a[1]:-}" || exit 2; sudo -n "\$H" journal-kernel "\${a[1]}" ;;
    zpool-status) zpool status -v ;;
    zpool-list)  zpool list ;;
    sensors)     command -v sensors >/dev/null && sensors || echo "lm-sensors nicht installiert" ;;
    lsblk)       lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT ;;
    uptime)      uptime ;;
    pveversion)  command -v pveversion >/dev/null && pveversion -v || echo "kein Proxmox" ;;
    free)        free -m ;;
    df)          df -hT -x tmpfs -x devtmpfs ;;
    *)           echo "nicht erlaubt" >&2; exit 2 ;;
esac
EOF
chown root:root "${LIBEXEC}/ssh-wrapper"; chmod 0755 "${LIBEXEC}/ssh-wrapper"

# 4) sudo nur für das Hilfsskript, ohne Passwort, ohne Umgebung
cat >"${SUDOERS}.tmp" <<EOF
Defaults:${DIAG_USER} !requiretty, env_reset
${DIAG_USER} ALL=(root) NOPASSWD: ${LIBEXEC}/root-helper
EOF
visudo -cf "${SUDOERS}.tmp" >/dev/null || { rm -f "${SUDOERS}.tmp"; die "sudoers ungültig"; }
install -m 0440 -o root -g root "${SUDOERS}.tmp" "${SUDOERS}"; rm -f "${SUDOERS}.tmp"

# 5) authorized_keys: Key nur von Hermes-IP, nur Wrapper, keine Extras
home="$(getent passwd "${DIAG_USER}" | cut -d: -f6)"
install -d -m 0700 -o "${DIAG_USER}" -g "${DIAG_USER}" "${home}/.ssh"
printf 'from="%s",command="%s/ssh-wrapper",restrict %s\n' "${HERMES_FROM}" "${LIBEXEC}" "${HERMES_PUBKEY}" >"${home}/.ssh/authorized_keys"
# Key-Datei gehört root, damit der User sie nicht ändern kann
chown root:"${DIAG_USER}" "${home}/.ssh/authorized_keys"; chmod 0640 "${home}/.ssh/authorized_keys"
chown root:"${DIAG_USER}" "${home}/.ssh"; chmod 0750 "${home}/.ssh"

# 6) Selbsttest
sudo -n -u "${DIAG_USER}" sudo -n -l "${LIBEXEC}/root-helper" >/dev/null || die "sudo-Regel greift nicht"
sudo -n -u "${DIAG_USER}" env SSH_ORIGINAL_COMMAND="smart-scan" "${LIBEXEC}/ssh-wrapper" >/dev/null || die "Selbsttest smart-scan fehlgeschlagen"
printf 'User %s auf %s eingerichtet (Zugriff nur von %s).\n' "${DIAG_USER}" "$(hostname)" "${HERMES_FROM}"
