#!/usr/bin/env bash
# Einrichtungsmenü für neue Hosts: zeigt die Skripte aus install/ zur Auswahl
# und führt die gewählten der Reihe nach aus.
#
# Neue VM einrichten (als root):
#   curl -fsSL https://raw.githubusercontent.com/bernadoDavinci/infra-scripts/main/setup.sh | sudo bash
#
# Ohne Menü (z. B. für Automatisierung):
#   ... | sudo bash -s -- auto-updates alloy     # nur diese
#   ... | sudo bash -s -- all                    # alle
#
# Aus einem Klon heraus (bash setup.sh) werden die lokalen Skripte verwendet,
# sonst lädt setup.sh sie vom selben Ref (Standard: main, Override: REF=<tag|commit>).
#
# Neues Skript aufnehmen: Datei nach install/ legen und unten in SCRIPTS eintragen.
set -Eeuo pipefail

readonly REPO_RAW="https://raw.githubusercontent.com/bernadoDavinci/infra-scripts"
readonly REF="${REF:-main}"

# name | Datei in install/ | Beschreibung (kurz, fürs Menü)
readonly SCRIPTS='
auto-updates | auto-updates.sh | Automatische Sicherheitsupdates (unattended-upgrades)
hermes-diag  | hermes-diag.sh  | Nur-Lese-Diagnosezugang für Hermes (SSH-Key, eng begrenzt)
alloy        | alloy.sh        | Grafana Alloy: Journal -> Loki
'

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

[[ ${EUID} -eq 0 ]] || die "als root ausführen, z. B.: curl -fsSL ${REPO_RAW}/main/setup.sh | sudo bash"

names=(); files=(); descs=()
while IFS='|' read -r n f d; do
    n="$(trim "${n}")"; [[ -z "${n}" ]] && continue
    names+=("${n}"); files+=("$(trim "${f}")"); descs+=("$(trim "${d}")")
done <<<"${SCRIPTS}"

# Lokaler Klon oder Download?
local_dir=""
self="${BASH_SOURCE[0]:-}"
if [[ -n "${self}" && -f "${self}" ]]; then
    d="$(cd "$(dirname "${self}")" && pwd)"
    [[ -d "${d}/install" ]] && local_dir="${d}/install"
fi

has_tty=0
if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then has_tty=1; fi

# --- Auswahl ---------------------------------------------------------------
selected=()
index_of() { local i; for i in "${!names[@]}"; do [[ "${names[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done; return 1; }

if [[ $# -gt 0 ]]; then
    for a in "$@"; do
        if [[ "${a}" == "all" ]]; then selected=("${!names[@]}"); break; fi
        i="$(index_of "${a}")" || die "unbekanntes Skript: ${a} (verfügbar: ${names[*]}, all)"
        selected+=("${i}")
    done
elif [[ ${has_tty} -eq 0 ]]; then
    die "kein Terminal für das Menü – Skripte als Argumente angeben: ${names[*]} oder all"
elif command -v whiptail >/dev/null 2>&1; then
    items=()
    for i in "${!names[@]}"; do items+=("${names[$i]}" "${descs[$i]}" "ON"); done
    choice="$(whiptail --title "infra-scripts setup – $(hostname)" --separate-output \
        --checklist "Auswahl mit Leertaste, Bestätigen mit Enter:" 15 78 "${#names[@]}" \
        "${items[@]}" 3>&1 1>&2 2>&3 </dev/tty)" || { echo "Abgebrochen."; exit 0; }
    while read -r n; do
        [[ -n "${n}" ]] && selected+=("$(index_of "${n}")")
    done <<<"${choice}"
else
    printf '\ninfra-scripts setup – %s\n\n' "$(hostname)"
    for i in "${!names[@]}"; do printf '  %d) %-13s %s\n' "$((i + 1))" "${names[$i]}" "${descs[$i]}"; done
    printf '\n  a) alle    q) abbrechen\n\n'
    read -r -p "Auswahl (z. B. 1 3): " answer </dev/tty || answer="q"
    case "${answer}" in
        q|Q|"") echo "Abgebrochen."; exit 0 ;;
        a|A) selected=("${!names[@]}") ;;
        *)
            for t in ${answer//,/ }; do
                if ! [[ "${t}" =~ ^[0-9]+$ ]] || (( t < 1 || t > ${#names[@]} )); then
                    die "ungültige Auswahl: ${t}"
                fi
                selected+=("$((t - 1))")
            done ;;
    esac
fi
[[ ${#selected[@]} -gt 0 ]] || { echo "Nichts ausgewählt."; exit 0; }

# --- Ausführen -------------------------------------------------------------
command -v curl >/dev/null 2>&1 || [[ -n "${local_dir}" ]] \
    || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

results=()
for i in "${selected[@]}"; do
    n="${names[$i]}"; f="${files[$i]}"
    printf '\n==================== %s ====================\n' "${n}"
    if [[ -n "${local_dir}" ]]; then
        script="${local_dir}/${f}"
    else
        script="${tmp}/${f}"
        if ! curl -fsSL "${REPO_RAW}/${REF}/install/${f}" -o "${script}"; then
            results+=("FEHLER  ${n} (Download)"); continue
        fi
    fi
    bash -n "${script}" || { results+=("FEHLER  ${n} (Syntax)"); continue; }
    if [[ ${has_tty} -eq 1 ]]; then rc=0; bash "${script}" </dev/tty || rc=$?
    else rc=0; bash "${script}" </dev/null || rc=$?; fi
    if [[ ${rc} -eq 0 ]]; then results+=("OK      ${n}"); else results+=("FEHLER  ${n} (Exit ${rc})"); fi
done

printf '\n==================== Ergebnis (%s) ====================\n' "$(hostname)"
printf '  %s\n' "${results[@]}"
for r in "${results[@]}"; do [[ "${r}" == FEHLER* ]] && exit 1; done
exit 0
