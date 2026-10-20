#!/usr/bin/env bash
# shellcheck disable=SC2016  # $ARG/${ARG} stehen absichtlich wörtlich im generierten Wrapper
# Legt einen eng begrenzten, nur lesenden Diagnose-Zugang für Hermes an.
#
# Aufruf (als root):
#   bash hermes-diag.sh hostType=pve     # Proxmox-Node: inkl. smartctl, zpool
#   bash hermes-diag.sh hostType=vm      # VM/LXC: ohne Platten-/ZFS-Befehle und -Pakete
#   bash hermes-diag.sh                  # erneut ausführen = aktualisieren
#   bash hermes-diag.sh --uninstall
#
# Auf pve fragt das Skript, ob es auch in alle laufenden LXC und VMs
# ausgerollt werden soll (LXC über pct exec, VMs über den QEMU-Guest-Agent).
# Ohne Rückfrage: guests=all bzw. guests=none.
#
# Der SSH-Server wird geprüft und bei Bedarf installiert/gestartet.
#
# Updates: Die erlaubten Befehle stehen nur in der Tabelle ALLOWED weiter unten.
# Neue Befehle dort eintragen und das Skript auf dem Host erneut ausführen –
# Wrapper, sudo-Regel und SSH-Key werden komplett neu geschrieben, entfernte
# Befehle sind danach auch wirklich weg. hostType wird in /etc/hermes-diag.conf
# gemerkt und muss beim Update nicht erneut angegeben werden.
#
# Sicherheitsmodell:
# - User "hermes": kein Passwort, Login nur per SSH-Key von der Hermes-VM.
# - authorized_keys: from=<Hermes-IP>, command=<Wrapper>, restrict
#   → keine Shell, kein PTY, kein SFTP, kein Port-/Agent-/X11-Forwarding.
# - Der Wrapper führt nur Befehle aus der Tabelle aus und prüft die Argumente.
#   Befehle mit Root-Bedarf laufen per sudo, aber nur über denselben
#   root-eigenen Wrapper, der die Prüfung als root wiederholt.
set -Eeuo pipefail

readonly VERSION="3"
readonly DIAG_USER="${DIAG_USER:-hermes}"
readonly MARKER="Hermes read-only diagnostics"
readonly HERMES_FROM="${HERMES_FROM:-172.22.20.25}"
readonly HERMES_PUBKEY="${HERMES_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG7G1D20qiD7LDc5X7ajQx0KUmF0rzPvDfoD9jJWC3xs hermes@hermesagent}"
readonly LIBEXEC="${LIBEXEC:-/usr/local/libexec/hermes-diag}"
readonly WRAPPER="${LIBEXEC}/diag"
readonly SUDOERS="/etc/sudoers.d/hermes-diag"
readonly CONF="/etc/hermes-diag.conf"

# ---------------------------------------------------------------------------
# Erlaubte Befehle:  name | hostType (all|pve) | root (0|1) | Argument | Befehl
#   Argument: none = keins, dev = Gerätename (nvme0n1, sda …), since = 24h/7d
#   Im Befehl steht $ARG für das geprüfte Argument.
# ---------------------------------------------------------------------------
readonly ALLOWED='
smart          | pve | 1 | dev   | smartctl -x "/dev/$ARG" || true
smart-scan     | pve | 1 | none  | smartctl --scan
nvme-log       | pve | 1 | dev   | if command -v nvme >/dev/null; then nvme smart-log "/dev/$ARG"; else echo "nvme-cli nicht installiert"; fi
zpool-status   | pve | 1 | none  | zpool status -v
zpool-list     | pve | 0 | none  | zpool list
pveversion     | pve | 0 | none  | pveversion -v
dmesg          | all | 1 | none  | dmesg --ctime --level=err,warn,crit,alert,emerg | tail -n 500
journal-kernel | all | 1 | since | journalctl -k --no-pager -p warning --since "-$ARG" | tail -n 1000
sensors        | all | 0 | none  | if command -v sensors >/dev/null; then sensors; else echo "lm-sensors nicht installiert"; fi
lsblk          | all | 0 | none  | lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT
uptime         | all | 0 | none  | uptime
free           | all | 0 | none  | free -m
df             | all | 0 | none  | df -hT -x tmpfs -x devtmpfs
'

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Erzeugt den Wrapper für einen hostType auf stdout.
generate_wrapper() {
    local host_type="$1" help="help" name scope root argt cmd
    cat <<EOF
#!/bin/bash
# Generiert von hermes-diag.sh v${VERSION} (hostType=${host_type}) – nicht von Hand ändern.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
SELF=${WRAPPER}
EOF
    cat <<'EOF'
check() {
    case "$1" in
        none)  [[ -z "${2:-}" ]] ;;
        dev)   [[ "${2:-}" =~ ^(nvme[0-9]+n[0-9]+|nvme[0-9]+|sd[a-z]{1,2})$ ]] && [[ -e "/dev/$2" ]] ;;
        since) [[ "${2:-}" =~ ^[0-9]{1,3}(h|d)$ ]] ;;
        *)     false ;;
    esac
}
if [[ "${1:-}" == "--as-root" ]]; then
    [[ ${EUID} -eq 0 && $# -le 3 ]] || exit 2
    name="${2:-}"; ARG="${3:-}"
else
    read -r -a w <<<"${SSH_ORIGINAL_COMMAND:-help}"
    [[ ${#w[@]} -le 2 ]] || { echo "zu viele Argumente" >&2; exit 2; }
    name="${w[0]:-help}"; ARG="${w[1]:-}"
fi
case "${name}" in
EOF
    while IFS='|' read -r name scope root argt cmd; do
        name="$(xargs <<<"${name}")"; [[ -z "${name}" ]] && continue
        scope="$(xargs <<<"${scope}")"; root="$(xargs <<<"${root}")"; argt="$(xargs <<<"${argt}")"
        cmd="${cmd# }"
        [[ "${scope}" == "all" || "${scope}" == "${host_type}" ]] || continue
        help+=" | ${name}"; [[ "${argt}" != "none" ]] && help+=" <${argt}>"
        printf '    %s)\n        check %s "${ARG}" || { echo "ungültiges Argument" >&2; exit 2; }\n' "${name}" "${argt}"
        if [[ "${root}" == "1" ]]; then
            printf '        if [[ ${EUID} -ne 0 ]]; then exec sudo -n "${SELF}" --as-root %s ${ARG:+"${ARG}"}; fi\n' "${name}"
        fi
        printf '        %s ;;\n' "${cmd}"
    done <<<"${ALLOWED}"
    printf '    help) echo "Erlaubt: %s" ;;\n' "${help}"
    printf '    *) echo "nicht erlaubt" >&2; exit 2 ;;\nesac\n'
}

# Nur Wrapper ausgeben (zum Prüfen ohne Root): bash hermes-diag.sh --print-wrapper hostType=vm
if [[ "${1:-}" == "--print-wrapper" ]]; then
    t="${2:-hostType=pve}"; generate_wrapper "${t#*=}"; exit 0
fi

[[ ${EUID} -eq 0 ]] || die "als root ausführen (z. B. mit sudo)"

host_type=""; uninstall=0; guests=""
for a in "$@"; do
    case "$a" in
        hostType=*|--host-type=*) host_type="${a#*=}" ;;
        guests=all|guests=none) guests="${a#*=}" ;;
        --uninstall) uninstall=1 ;;
        *) die "unbekannter Parameter: $a (erlaubt: hostType=pve|vm, guests=all|none, --uninstall)" ;;
    esac
done

user_is_ours() { [[ "$(getent passwd "${DIAG_USER}" | cut -d: -f5)" == "${MARKER}" ]]; }

if ((uninstall)); then
    rm -f "${SUDOERS}" "${CONF}"
    rm -rf "${LIBEXEC}"
    if id "${DIAG_USER}" >/dev/null 2>&1 && user_is_ours; then
        userdel -r "${DIAG_USER}" 2>/dev/null || userdel "${DIAG_USER}"
    fi
    printf '%s entfernt.\n' "${DIAG_USER}"
    exit 0
fi

# hostType: Parameter > gemerkter Wert > Erkennung
if [[ -z "${host_type}" && -r "${CONF}" ]]; then
    host_type="$(sed -n 's/^HOST_TYPE=//p' "${CONF}")"
fi
if [[ -z "${host_type}" ]]; then
    if command -v pveversion >/dev/null 2>&1; then host_type="pve"; else host_type="vm"; fi
    printf 'hostType nicht angegeben, erkannt: %s\n' "${host_type}"
fi
[[ "${host_type}" == "pve" || "${host_type}" == "vm" ]] || die "hostType muss pve oder vm sein"
[[ "${HERMES_PUBKEY}" =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "HERMES_PUBKEY ist kein SSH-Public-Key"

# Pakete: sudo immer, smartmontools nur auf pve
pkgs=()
command -v sudo >/dev/null 2>&1 || pkgs+=(sudo)
if [[ "${host_type}" == "pve" ]] && ! command -v smartctl >/dev/null 2>&1; then pkgs+=(smartmontools); fi
[[ -x /usr/sbin/sshd ]] || pkgs+=(openssh-server)
if ((${#pkgs[@]})); then
    command -v apt-get >/dev/null 2>&1 || die "fehlende Pakete (${pkgs[*]}) und kein apt-get"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq "${pkgs[@]}"
fi

# 0) SSH-Server muss laufen
command -v systemctl >/dev/null 2>&1 || die "kein systemd – SSH-Dienst bitte von Hand prüfen"
ssh_svc=""
for s in ssh sshd; do systemctl cat "${s}.service" >/dev/null 2>&1 && { ssh_svc="$s"; break; }; done
[[ -n "${ssh_svc}" ]] || die "kein ssh.service/sshd.service gefunden"
if ! systemctl is-active --quiet "${ssh_svc}.service" && ! systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl enable --now "${ssh_svc}.service"
fi
systemctl is-active --quiet "${ssh_svc}.service" || systemctl is-active --quiet ssh.socket 2>/dev/null \
    || die "SSH-Dienst läuft nicht"
if sshd_cfg="$(/usr/sbin/sshd -T 2>/dev/null)"; then
    if grep -qiE '^(allowusers|allowgroups) ' <<<"${sshd_cfg}" && ! grep -qiE "^allowusers .*\b${DIAG_USER}\b" <<<"${sshd_cfg}"; then
        printf 'Warnung: sshd hat AllowUsers/AllowGroups gesetzt – %s darf sich evtl. nicht anmelden.\n' "${DIAG_USER}" >&2
    fi
    grep -qi '^pubkeyauthentication no' <<<"${sshd_cfg}" && printf 'Warnung: PubkeyAuthentication ist deaktiviert.\n' >&2
fi

# 1) User: anlegen oder nur den eigenen weiterverwenden
if id "${DIAG_USER}" >/dev/null 2>&1; then
    user_is_ours || die "User ${DIAG_USER} existiert bereits und stammt nicht von diesem Skript – Abbruch"
else
    useradd --system --create-home --shell /bin/sh --comment "${MARKER}" "${DIAG_USER}"
fi
passwd -l "${DIAG_USER}" >/dev/null
for g in sudo adm wheel; do gpasswd -d "${DIAG_USER}" "$g" >/dev/null 2>&1 || true; done

# 2) Wrapper neu erzeugen (nur Befehle für diesen hostType)
install -d -m 0755 -o root -g root "${LIBEXEC}"
tmp="$(mktemp)"; trap 'rm -f "${tmp}" "${SUDOERS}.tmp"' EXIT
generate_wrapper "${host_type}" >"${tmp}"
bash -n "${tmp}" || die "erzeugter Wrapper ist fehlerhaft"
install -m 0755 -o root -g root "${tmp}" "${WRAPPER}"
rm -f "${LIBEXEC}/ssh-wrapper" "${LIBEXEC}/root-helper"   # Reste aus Version 1

# 3) sudo: nur der Wrapper im Root-Modus, ohne Passwort, ohne Umgebung
cat >"${SUDOERS}.tmp" <<EOF
Defaults:${DIAG_USER} !requiretty, env_reset
${DIAG_USER} ALL=(root) NOPASSWD: ${WRAPPER} --as-root *
EOF
visudo -cf "${SUDOERS}.tmp" >/dev/null || die "sudoers ungültig"
install -m 0440 -o root -g root "${SUDOERS}.tmp" "${SUDOERS}"

# 4) authorized_keys: nur Hermes-IP, nur Wrapper, alles andere gesperrt; Datei gehört root
home="$(getent passwd "${DIAG_USER}" | cut -d: -f6)"
install -d -m 0750 -o root -g "${DIAG_USER}" "${home}/.ssh"
printf 'from="%s",command="%s",restrict %s\n' "${HERMES_FROM}" "${WRAPPER}" "${HERMES_PUBKEY}" >"${home}/.ssh/authorized_keys"
chown root:"${DIAG_USER}" "${home}/.ssh/authorized_keys"; chmod 0640 "${home}/.ssh/authorized_keys"

printf 'HOST_TYPE=%s\nVERSION=%s\n' "${host_type}" "${VERSION}" >"${CONF}"; chmod 0644 "${CONF}"

# 5) Selbsttest als User
run_as() { sudo -n -u "${DIAG_USER}" env SSH_ORIGINAL_COMMAND="$1" "${WRAPPER}"; }
run_as "uptime" >/dev/null || die "Selbsttest uptime fehlgeschlagen"
run_as "journal-kernel 1h" >/dev/null || die "Selbsttest journal-kernel (sudo) fehlgeschlagen"
if run_as "id; rm -rf /" >/dev/null 2>&1; then die "Selbsttest: unerlaubter Befehl wurde akzeptiert"; fi
printf 'User %s auf %s eingerichtet (hostType=%s, Zugriff nur von %s).\n' "${DIAG_USER}" "$(hostname)" "${host_type}" "${HERMES_FROM}"
run_as "help"

# 6) Nur pve: optional in alle laufenden Gäste ausrollen (dort hostType=vm)
[[ "${host_type}" == "pve" ]] || exit 0
command -v pct >/dev/null 2>&1 || exit 0
if [[ -z "${guests}" ]]; then
    if [[ -r /dev/tty ]]; then
        read -r -p "Auch in allen laufenden LXC und VMs einrichten? [j/N] " ans </dev/tty || ans=""
        [[ "${ans}" =~ ^[jJyY]$ ]] && guests="all" || guests="none"
    else
        guests="none"
    fi
fi
[[ "${guests}" == "all" ]] || exit 0
self="$(readlink -f "$0")"
[[ -f "${self}" ]] || die "Ausrollen geht nur, wenn das Skript als Datei ausgeführt wird (nicht per Pipe)"

ok=(); fail=()
while read -r id; do
    [[ -n "${id}" ]] || continue
    if ! pct exec "${id}" -- sh -c 'command -v bash >/dev/null && command -v apt-get >/dev/null' </dev/null; then
        fail+=("CT ${id}: kein bash/apt (übersprungen)"); continue
    fi
    printf '\n== CT %s ==\n' "${id}"
    if pct push "${id}" "${self}" /root/hermes-diag.sh --perms 0700 \
        && pct exec "${id}" -- bash /root/hermes-diag.sh hostType=vm guests=none </dev/null; then
        ok+=("CT ${id}")
    else
        fail+=("CT ${id}: Fehler")
    fi
done < <(pct list | awk 'NR>1 && $2=="running" {print $1}')

while read -r id; do
    [[ -n "${id}" ]] || continue
    if ! qm guest cmd "${id}" ping </dev/null >/dev/null 2>&1; then fail+=("VM ${id}: kein Guest-Agent (übersprungen)"); continue; fi
    printf '\n== VM %s ==\n' "${id}"
    out="$(qm guest exec "${id}" --pass-stdin 1 --timeout 600 -- bash -c \
        'cat >/root/hermes-diag.sh && chmod 0700 /root/hermes-diag.sh && bash /root/hermes-diag.sh hostType=vm guests=none </dev/null' \
        <"${self}" 2>&1 || true)"
    if grep -qE '"exitcode" *: *0' <<<"${out}"; then ok+=("VM ${id}"); else fail+=("VM ${id}: Fehler (kein Debian/apt?)"); fi
done < <(qm list | awk 'NR>1 && $3=="running" {print $1}')

printf '\nAusgerollt: %s\n' "${ok[*]:-keine}"
((${#fail[@]})) && printf 'Nicht eingerichtet:\n  %s\n' "${fail[@]}"
exit 0
