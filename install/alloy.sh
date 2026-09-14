#!/usr/bin/env bash
set -Eeuo pipefail

readonly GRAFANA_KEY_URL="https://apt.grafana.com/gpg.key"
readonly GRAFANA_KEYRING="/etc/apt/keyrings/grafana.gpg"
readonly GRAFANA_REPOSITORY="deb [signed-by=${GRAFANA_KEYRING}] https://apt.grafana.com stable main"
readonly GRAFANA_SOURCE="/etc/apt/sources.list.d/grafana.list"
readonly ALLOY_CONFIG="/etc/alloy/config.alloy"
readonly LOKI_URL="${LOKI_URL:-http://172.22.20.27:3100/loki/api/v1/push}"
readonly LOKI_TENANT_ID="${LOKI_TENANT_ID:-fake}"

if [[ ${EUID} -ne 0 ]]; then
    printf 'Error: Run this script as root (for example with sudo).\n' >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    printf 'Error: This installer currently supports Debian/Ubuntu systems with apt only.\n' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg

install -d -m 0755 /etc/apt/keyrings
key_tmp="$(mktemp)"
trap 'rm -f "${key_tmp}"' EXIT
curl -fsSL "${GRAFANA_KEY_URL}" | gpg --dearmor --yes -o "${key_tmp}"
install -m 0644 "${key_tmp}" "${GRAFANA_KEYRING}"
printf '%s\n' "${GRAFANA_REPOSITORY}" >"${GRAFANA_SOURCE}"

apt-get update
apt-get install -y alloy

install -d -m 0755 /etc/alloy
cat >"${ALLOY_CONFIG}" <<EOF
loki.write "default" {
    endpoint {
        url       = "${LOKI_URL}"
        tenant_id = "${LOKI_TENANT_ID}"
    }
}

loki.relabel "journal" {
    forward_to = []
    rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "service_name"
    }
    rule {
        target_label = "hostname"
        replacement  = constants.hostname
    }
}

loki.source.journal "systemd" {
    relabel_rules = loki.relabel.journal.rules
    forward_to    = [loki.relabel.cleanup.receiver]
}

loki.relabel "cleanup" {
    forward_to = [loki.process.addhost.receiver]
    rule {
        action = "labeldrop"
        regex  = "job"
    }
}

loki.process "addhost" {
    forward_to = [loki.write.default.receiver]
}
EOF
chmod 0644 "${ALLOY_CONFIG}"

if ! alloy validate "${ALLOY_CONFIG}"; then
    printf 'Error: Alloy configuration validation failed.\n' >&2
    exit 1
fi

systemctl enable --now alloy
systemctl restart alloy
systemctl --no-pager --full status alloy

logger -p user.notice "alloy-test"
printf 'Alloy installed. Test journal entry sent with logger.\n'
