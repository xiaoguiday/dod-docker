#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Cloudflare WARP MASQUE L4 Relay
# Version: 2.1.0
#
# Supported:
#   - Synology DSM 6.x / 7.x
#   - fnOS
#   - Debian
#   - Ubuntu
#
# Features:
#   - IPv4 TCP/UDP DNAT
#   - IPv6 TCP/UDP DNAT
#   - IPv4 / IPv6 MASQUERADE
#   - IPv4 / IPv6 forwarding
#   - nftables / iptables automatic detection
#   - systemd / Synology startup
#   - install / status / test / start / stop / restart / uninstall
#
# Default:
#   IPv4 Endpoint : 162.159.197.2:443
#   IPv6 Endpoint : 2606:4700:102::2:443
#   Relay Port    : 65535
# ============================================================

SCRIPT_NAME="warp-masque-relay"
VERSION="2.1.0"

DEFAULT_CF_IPV4="162.159.197.2"
DEFAULT_CF_IPV6="2606:4700:102::2"
DEFAULT_CF_PORT="443"
DEFAULT_LISTEN_PORT="65535"

STATE_DIR="/etc/warp-masque-relay"
CONFIG_FILE="${STATE_DIR}/config"

NFT_V4_FILE="${STATE_DIR}/warp-relay-ipv4.nft"
NFT_V6_FILE="${STATE_DIR}/warp-relay-ipv6.nft"

NFT_SERVICE="/etc/systemd/system/warp-masque-relay.service"

DSM_RC="/usr/local/etc/rc.d/S99warp-masque-relay.sh"

CF_IPV4=""
CF_IPV6=""
CF_PORT=""
LISTEN_PORT=""

SYSTEM=""
VERSION_INFO=""
KERNEL=""
ARCH=""
FIREWALL=""
NFT_BIN=""

# ============================================================
# Basic
# ============================================================

log() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

err() {
    echo "[ERROR] $*" >&2
}

die() {
    err "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "请使用 root 运行此脚本。"
    fi
}

# ============================================================
# Detect OS
# ============================================================

detect_system() {

    KERNEL="$(uname -r 2>/dev/null || echo unknown)"
    ARCH="$(uname -m 2>/dev/null || echo unknown)"

    # --------------------------------------------------------
    # Synology
    # --------------------------------------------------------

    if [[ -f /etc.defaults/VERSION ]]; then

        SYSTEM="synology"

        VERSION_INFO="$(
            awk -F'"' '
                /productversion/ {
                    print $2
                    exit
                }
            ' /etc.defaults/VERSION 2>/dev/null || true
        )"

        [[ -n "$VERSION_INFO" ]] || VERSION_INFO="unknown"

        FIREWALL="iptables"

        return
    fi

    # --------------------------------------------------------
    # /etc/os-release
    # --------------------------------------------------------

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release || true
    fi

    local id="${ID:-}"
    local version="${VERSION_ID:-unknown}"
    local pretty="${PRETTY_NAME:-}"

    # --------------------------------------------------------
    # fnOS
    # --------------------------------------------------------

    if [[ "${id,,}" == "fnos" ]] ||
       [[ "${pretty,,}" == *"fnos"* ]]; then

        SYSTEM="fnos"
        VERSION_INFO="$version"
        FIREWALL="nftables"

        return
    fi

    # --------------------------------------------------------
    # Ubuntu
    # --------------------------------------------------------

    if [[ "${id,,}" == "ubuntu" ]]; then

        SYSTEM="ubuntu"
        VERSION_INFO="$version"
        FIREWALL="nftables"

        return
    fi

    # --------------------------------------------------------
    # Debian
    # --------------------------------------------------------

    if [[ "${id,,}" == "debian" ]]; then

        SYSTEM="debian"
        VERSION_INFO="$version"
        FIREWALL="nftables"

        return
    fi

    # --------------------------------------------------------
    # Unknown
    # --------------------------------------------------------

    SYSTEM="unknown"
    VERSION_INFO="unknown"
}

# ============================================================
# Detect firewall
# ============================================================

detect_firewall() {

    case "$SYSTEM" in

        synology)

            if command_exists iptables &&
               command_exists ip6tables; then

                FIREWALL="iptables"

            elif command_exists iptables; then

                warn "找到 iptables，但没有 ip6tables。"
                FIREWALL="iptables"

            else

                die "Synology 没有找到 iptables。"
            fi

            ;;

        fnos|debian|ubuntu)

            if command_exists nft; then

                FIREWALL="nftables"
                NFT_BIN="$(command -v nft)"

            elif command_exists iptables; then

                warn "未找到 nft，回退到 iptables。"
                FIREWALL="iptables"

            else

                die "既没有 nft，也没有 iptables。"
            fi

            ;;

        *)

            if command_exists nft; then

                FIREWALL="nftables"
                NFT_BIN="$(command -v nft)"

            elif command_exists iptables; then

                FIREWALL="iptables"

            else

                die "无法找到 nft 或 iptables。"
            fi

            ;;
    esac

    if [[ "$FIREWALL" == "nftables" ]] &&
       [[ -z "$NFT_BIN" ]]; then

        NFT_BIN="$(command -v nft || true)"
    fi
}

# ============================================================
# Dependencies
# ============================================================

install_dependencies() {

    case "$FIREWALL" in

        nftables)

            if command_exists nft; then
                NFT_BIN="$(command -v nft)"
                return
            fi

            log "正在安装 nftables..."

            if command_exists apt-get; then

                export DEBIAN_FRONTEND=noninteractive

                apt-get update
                apt-get install -y \
                    nftables \
                    iproute2 \
                    curl

            elif command_exists dnf; then

                dnf install -y \
                    nftables \
                    iproute \
                    curl

            elif command_exists yum; then

                yum install -y \
                    nftables \
                    iproute \
                    curl

            elif command_exists apk; then

                apk add \
                    nftables \
                    iproute2 \
                    curl

            else

                die "找不到可用的软件包管理器。"
            fi

            NFT_BIN="$(command -v nft)"

            ;;

        iptables)

            if command_exists iptables &&
               command_exists ip6tables; then

                return
            fi

            log "正在安装 iptables..."

            if command_exists apt-get; then

                export DEBIAN_FRONTEND=noninteractive

                apt-get update
                apt-get install -y \
                    iptables \
                    iproute2 \
                    curl

            elif command_exists dnf; then

                dnf install -y \
                    iptables \
                    iproute \
                    curl

            elif command_exists yum; then

                yum install -y \
                    iptables \
                    iproute \
                    curl

            elif command_exists apk; then

                apk add \
                    iptables \
                    ip6tables \
                    iproute2 \
                    curl

            else

                die "找不到可用的软件包管理器。"
            fi

            ;;
    esac
}

# ============================================================
# Validate IPv4
# ============================================================

validate_ipv4() {

    local ip="$1"

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        return 1

    local IFS=.
    local octet

    read -ra octets <<< "$ip"

    for octet in "${octets[@]}"; do

        (( octet >= 0 && octet <= 255 )) ||
            return 1
    done

    return 0
}

# ============================================================
# Validate IPv6
# ============================================================

validate_ipv6() {

    local ip="$1"

    if command_exists python3; then

        python3 - "$ip" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv6Address(sys.argv[1])
except Exception:
    sys.exit(1)
PY

        return $?
    fi

    [[ "$ip" == *:* ]]
}

# ============================================================
# Input configuration
# ============================================================

input_configuration() {

    echo
    echo "=========================================="
    echo " WARP MASQUE Relay 配置"
    echo "=========================================="
    echo

    read -r -p \
        "IPv4 Endpoint [${DEFAULT_CF_IPV4}]: " \
        INPUT_IPV4

    CF_IPV4="${INPUT_IPV4:-$DEFAULT_CF_IPV4}"

    read -r -p \
        "IPv6 Endpoint [${DEFAULT_CF_IPV6}]: " \
        INPUT_IPV6

    CF_IPV6="${INPUT_IPV6:-$DEFAULT_CF_IPV6}"

    read -r -p \
        "Cloudflare Endpoint Port [${DEFAULT_CF_PORT}]: " \
        INPUT_CF_PORT

    CF_PORT="${INPUT_CF_PORT:-$DEFAULT_CF_PORT}"

    read -r -p \
        "Relay Port [${DEFAULT_LISTEN_PORT}]: " \
        INPUT_LISTEN

    LISTEN_PORT="${INPUT_LISTEN:-$DEFAULT_LISTEN_PORT}"

    # Disable IPv6

    case "${CF_IPV6,,}" in
        none|disable|off|-)
            CF_IPV6=""
            ;;
    esac

    validate_configuration
}

# ============================================================
# Validate configuration
# ============================================================

validate_configuration() {

    [[ -n "$CF_IPV4" ]] ||
        die "IPv4 Endpoint 不能为空。"

    validate_ipv4 "$CF_IPV4" ||
        die "IPv4 Endpoint 格式错误：$CF_IPV4"

    [[ "$CF_PORT" =~ ^[0-9]+$ ]] ||
        die "Cloudflare Port 必须是数字。"

    [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] ||
        die "Relay Port 必须是数字。"

    (( CF_PORT >= 1 && CF_PORT <= 65535 )) ||
        die "Cloudflare Port 范围错误。"

    (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) ||
        die "Relay Port 范围错误。"

    if [[ -n "$CF_IPV6" ]]; then

        validate_ipv6 "$CF_IPV6" ||
            die "IPv6 Endpoint 格式错误：$CF_IPV6"
    fi
}

# ============================================================
# Show configuration
# ============================================================

show_configuration() {

    echo
    echo "=========================================="
    echo " Relay 配置确认"
    echo "=========================================="
    echo

    echo "系统          : $SYSTEM"
    echo "系统版本      : $VERSION_INFO"
    echo "Kernel        : $KERNEL"
    echo "架构          : $ARCH"
    echo "防火墙        : $FIREWALL"

    echo

    echo "IPv4 Endpoint : ${CF_IPV4}:${CF_PORT}"

    if [[ -n "$CF_IPV6" ]]; then
        echo "IPv6 Endpoint : [${CF_IPV6}]:${CF_PORT}"
    else
        echo "IPv6 Endpoint : DISABLED"
    fi

    echo "Relay Port    : ${LISTEN_PORT}"

    echo
    echo "TCP           : ENABLE"
    echo "UDP           : ENABLE"

    echo
    echo "=========================================="
}

# ============================================================
# Forwarding
# ============================================================

enable_forwarding() {

    log "开启 IPv4 forwarding..."

    sysctl -w net.ipv4.ip_forward=1 \
        >/dev/null 2>&1 || true

    mkdir -p /etc/sysctl.d

    if [[ -n "$CF_IPV6" ]]; then

        log "开启 IPv6 forwarding..."

        sysctl -w net.ipv6.conf.all.forwarding=1 \
            >/dev/null 2>&1 || true

        sysctl -w net.ipv6.conf.default.forwarding=1 \
            >/dev/null 2>&1 || true

        cat > /etc/sysctl.d/99-warp-masque-relay.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    else

        cat > /etc/sysctl.d/99-warp-masque-relay.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

    fi

    sysctl --system \
        >/dev/null 2>&1 || true
}

# ============================================================
# Save configuration
# ============================================================

save_configuration() {

    mkdir -p "$STATE_DIR"

    cat > "$CONFIG_FILE" <<EOF
CF_IPV4="$CF_IPV4"
CF_IPV6="$CF_IPV6"
CF_PORT="$CF_PORT"
LISTEN_PORT="$LISTEN_PORT"
SYSTEM="$SYSTEM"
VERSION_INFO="$VERSION_INFO"
KERNEL="$KERNEL"
ARCH="$ARCH"
FIREWALL="$FIREWALL"
EOF

    chmod 600 "$CONFIG_FILE"
}

# ============================================================
# nftables rule generation
# ============================================================

create_nft_rules() {

    mkdir -p "$STATE_DIR"

    # --------------------------------------------------------
    # IPv4
    # --------------------------------------------------------

    cat > "$NFT_V4_FILE" <<EOF
table ip warp_masque_relay {

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        tcp dport ${LISTEN_PORT} dnat to ${CF_IPV4}:${CF_PORT}
        udp dport ${LISTEN_PORT} dnat to ${CF_IPV4}:${CF_PORT}
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        ip daddr ${CF_IPV4} masquerade
    }
}
EOF

    # --------------------------------------------------------
    # IPv6
    # --------------------------------------------------------

    if [[ -n "$CF_IPV6" ]]; then

        cat > "$NFT_V6_FILE" <<EOF
table ip6 warp_masque_relay6 {

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        tcp dport ${LISTEN_PORT} dnat to ${CF_IPV6}:${CF_PORT}
        udp dport ${LISTEN_PORT} dnat to ${CF_IPV6}:${CF_PORT}
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        ip6 daddr ${CF_IPV6} masquerade
    }
}
EOF

    else

        rm -f "$NFT_V6_FILE"
    fi
}

# ============================================================
# Delete nft tables
# ============================================================

delete_nft_tables() {

    [[ -n "$NFT_BIN" ]] || return 0

    "$NFT_BIN" delete table ip warp_masque_relay \
        >/dev/null 2>&1 || true

    "$NFT_BIN" delete table ip6 warp_masque_relay6 \
        >/dev/null 2>&1 || true
}

# ============================================================
# Validate nft files
# ============================================================

validate_nft_rules() {

    [[ -n "$NFT_BIN" ]] ||
        die "nft binary 未找到。"

    "$NFT_BIN" -c -f "$NFT_V4_FILE" ||
        die "IPv4 nftables 配置检查失败。"

    if [[ -n "$CF_IPV6" ]] &&
       [[ -f "$NFT_V6_FILE" ]]; then

        "$NFT_BIN" -c -f "$NFT_V6_FILE" ||
            die "IPv6 nftables 配置检查失败。"
    fi
}

# ============================================================
# Load nft rules
# ============================================================

load_nft_rules() {

    [[ -n "$NFT_BIN" ]] ||
        die "nft binary 未找到。"

    validate_nft_rules

    delete_nft_tables

    log "加载 nftables IPv4..."

    "$NFT_BIN" -f "$NFT_V4_FILE"

    if [[ -n "$CF_IPV6" ]] &&
       [[ -f "$NFT_V6_FILE" ]]; then

        log "加载 nftables IPv6..."

        "$NFT_BIN" -f "$NFT_V6_FILE"
    fi
}

# ============================================================
# systemd service
# ============================================================

create_nft_systemd_service() {

    command_exists systemctl || return 0

    local nft_path="$NFT_BIN"

    cat > "$NFT_SERVICE" <<EOF
[Unit]
Description=Cloudflare WARP MASQUE Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

ExecStart=/bin/sh -c '${nft_path} delete table ip warp_masque_relay >/dev/null 2>&1 || true; ${nft_path} -f ${NFT_V4_FILE}'

ExecStart=/bin/sh -c '${nft_path} delete table ip6 warp_masque_relay6 >/dev/null 2>&1 || true; if [ -f ${NFT_V6_FILE} ]; then ${nft_path} -f ${NFT_V6_FILE}; fi'

ExecStop=/bin/sh -c '${nft_path} delete table ip warp_masque_relay >/dev/null 2>&1 || true; ${nft_path} delete table ip6 warp_masque_relay6 >/dev/null 2>&1 || true'

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable warp-masque-relay.service \
        >/dev/null 2>&1 || true

    systemctl restart warp-masque-relay.service
}

# ============================================================
# nft startup fallback
# ============================================================

create_nft_startup_fallback() {

    command_exists systemctl && return 0

    if [[ "$SYSTEM" == "fnos" ]] &&
       [[ -d /etc/rc.d ]]; then

        cat > /etc/rc.d/S99warp-masque-relay <<EOF
#!/bin/sh

case "\$1" in
    start|restart)
        ${NFT_BIN} delete table ip warp_masque_relay >/dev/null 2>&1 || true
        ${NFT_BIN} delete table ip6 warp_masque_relay6 >/dev/null 2>&1 || true
        ${NFT_BIN} -f ${NFT_V4_FILE}
        [ -f ${NFT_V6_FILE} ] && ${NFT_BIN} -f ${NFT_V6_FILE}
        ;;
    stop)
        ${NFT_BIN} delete table ip warp_masque_relay >/dev/null 2>&1 || true
        ${NFT_BIN} delete table ip6 warp_masque_relay6 >/dev/null 2>&1 || true
        ;;
esac

exit 0
EOF

        chmod +x /etc/rc.d/S99warp-masque-relay
    fi
}

# ============================================================
# iptables rule check
# ============================================================

iptables_rule_exists() {

    local family="$1"
    shift

    if [[ "$family" == "ipv4" ]]; then
        iptables -C "$@" >/dev/null 2>&1
    else
        ip6tables -C "$@" >/dev/null 2>&1
    fi
}

# ============================================================
# iptables
# ============================================================

create_iptables_rules() {

    # --------------------------------------------------------
    # IPv4 TCP
    # --------------------------------------------------------

    if ! iptables_rule_exists ipv4 \
        -t nat -A PREROUTING \
        -p tcp \
        --dport "$LISTEN_PORT" \
        -j DNAT \
        --to-destination "${CF_IPV4}:${CF_PORT}" \
        -m comment \
        --comment WARP-MASQUE-RELAY; then

        iptables -t nat -A PREROUTING \
            -p tcp \
            --dport "$LISTEN_PORT" \
            -j DNAT \
            --to-destination "${CF_IPV4}:${CF_PORT}" \
            -m comment \
            --comment WARP-MASQUE-RELAY
    fi

    # --------------------------------------------------------
    # IPv4 UDP
    # --------------------------------------------------------

    if ! iptables_rule_exists ipv4 \
        -t nat -A PREROUTING \
        -p udp \
        --dport "$LISTEN_PORT" \
        -j DNAT \
        --to-destination "${CF_IPV4}:${CF_PORT}" \
        -m comment \
        --comment WARP-MASQUE-RELAY; then

        iptables -t nat -A PREROUTING \
            -p udp \
            --dport "$LISTEN_PORT" \
            -j DNAT \
            --to-destination "${CF_IPV4}:${CF_PORT}" \
            -m comment \
            --comment WARP-MASQUE-RELAY
    fi

    # --------------------------------------------------------
    # IPv4 MASQUERADE
    # --------------------------------------------------------

    if ! iptables_rule_exists ipv4 \
        -t nat -A POSTROUTING \
        -d "$CF_IPV4" \
        -j MASQUERADE \
        -m comment \
        --comment WARP-MASQUE-RELAY; then

        iptables -t nat -A POSTROUTING \
            -d "$CF_IPV4" \
            -j MASQUERADE \
            -m comment \
            --comment WARP-MASQUE-RELAY
    fi

    # --------------------------------------------------------
    # IPv4 FORWARD
    # --------------------------------------------------------

    if ! iptables_rule_exists ipv4 \
        -A FORWARD \
        -p tcp \
        -d "$CF_IPV4" \
        --dport "$CF_PORT" \
        -j ACCEPT \
        -m comment \
        --comment WARP-MASQUE-RELAY; then

        iptables -A FORWARD \
            -p tcp \
            -d "$CF_IPV4" \
            --dport "$CF_PORT" \
            -j ACCEPT \
            -m comment \
            --comment WARP-MASQUE-RELAY
    fi

    if ! iptables_rule_exists ipv4 \
        -A FORWARD \
        -p udp \
        -d "$CF_IPV4" \
        --dport "$CF_PORT" \
        -j ACCEPT \
        -m comment \
        --comment WARP-MASQUE-RELAY; then

        iptables -A FORWARD \
            -p udp \
            -d "$CF_IPV4" \
            --dport "$CF_PORT" \
            -j ACCEPT \
            -m comment \
            --comment WARP-MASQUE-RELAY
    fi

    # --------------------------------------------------------
    # IPv6
    # --------------------------------------------------------

    if [[ -n "$CF_IPV6" ]] &&
       command_exists ip6tables; then

        # IPv6 TCP DNAT

        if ! iptables_rule_exists ipv6 \
            -t nat -A PREROUTING \
            -p tcp \
            --dport "$LISTEN_PORT" \
            -j DNAT \
            --to-destination "${CF_IPV6}:${CF_PORT}" \
            -m comment \
            --comment WARP-MASQUE-RELAY; then

            ip6tables -t nat -A PREROUTING \
                -p tcp \
                --dport "$LISTEN_PORT" \
                -j DNAT \
                --to-destination "${CF_IPV6}:${CF_PORT}" \
                -m comment \
                --comment WARP-MASQUE-RELAY
        fi

        # IPv6 UDP DNAT

        if ! iptables_rule_exists ipv6 \
            -t nat -A PREROUTING \
            -p udp \
            --dport "$LISTEN_PORT" \
            -j DNAT \
            --to-destination "${CF_IPV6}:${CF_PORT}" \
            -m comment \
            --comment WARP-MASQUE-RELAY; then

            ip6tables -t nat -A PREROUTING \
                -p udp \
                --dport "$LISTEN_PORT" \
                -j DNAT \
                --to-destination "${CF_IPV6}:${CF_PORT}" \
                -m comment \
                --comment WARP-MASQUE-RELAY
        fi

        # IPv6 MASQUERADE

        if ! iptables_rule_exists ipv6 \
            -t nat -A POSTROUTING \
            -d "$CF_IPV6" \
            -j MASQUERADE \
            -m comment \
            --comment WARP-MASQUE-RELAY; then

            ip6tables -t nat -A POSTROUTING \
                -d "$CF_IPV6" \
                -j MASQUERADE \
                -m comment \
                --comment WARP-MASQUE-RELAY
        fi

        # IPv6 FORWARD TCP

        if ! iptables_rule_exists ipv6 \
            -A FORWARD \
            -p tcp \
            -d "$CF_IPV6" \
            --dport "$CF_PORT" \
            -j ACCEPT \
            -m comment \
            --comment WARP-MASQUE-RELAY; then

            ip6tables -A FORWARD \
                -p tcp \
                -d "$CF_IPV6" \
                --dport "$CF_PORT" \
                -j ACCEPT \
                -m comment \
                --comment WARP-MASQUE-RELAY
        fi

        # IPv6 FORWARD UDP

        if ! iptables_rule_exists ipv6 \
            -A FORWARD \
            -p udp \
            -d "$CF_IPV6" \
            --dport "$CF_PORT" \
            -j ACCEPT \
            -m comment \
            --comment WARP-MASQUE-RELAY; then

            ip6tables -A FORWARD \
                -p udp \
                -d "$CF_IPV6" \
                --dport "$CF_PORT" \
                -j ACCEPT \
                -m comment \
                --comment WARP-MASQUE-RELAY
        fi
    fi
}

# ============================================================
# Remove iptables rules
# ============================================================

remove_iptables_rules() {

    local table
    local rule

    if command_exists iptables; then

        for table in nat filter; do

            while true; do

                rule="$(
                    if [[ "$table" == "nat" ]]; then
                        iptables -t nat -S 2>/dev/null
                    else
                        iptables -S 2>/dev/null
                    fi |
                    grep 'WARP-MASQUE-RELAY' |
                    head -n1 ||
                    true
                )"

                [[ -n "$rule" ]] || break

                rule="$(echo "$rule" | sed 's/^-A /-D /')"

                if [[ "$table" == "nat" ]]; then
                    iptables -t nat $rule || true
                else
                    iptables $rule || true
                fi
            done
        done
    fi

    if command_exists ip6tables; then

        for table in nat filter; do

            while true; do

                rule="$(
                    if [[ "$table" == "nat" ]]; then
                        ip6tables -t nat -S 2>/dev/null
                    else
                        ip6tables -S 2>/dev/null
                    fi |
                    grep 'WARP-MASQUE-RELAY' |
                    head -n1 ||
                    true
                )"

                [[ -n "$rule" ]] || break

                rule="$(echo "$rule" | sed 's/^-A /-D /')"

                if [[ "$table" == "nat" ]]; then
                    ip6tables -t nat $rule || true
                else
                    ip6tables $rule || true
                fi
            done
        done
    fi
}

# ============================================================
# Copy script
# ============================================================

install_script_copy() {

    mkdir -p "$STATE_DIR"

    local source_script

    source_script="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

    if [[ -z "$source_script" ]] ||
       [[ ! -f "$source_script" ]]; then

        source_script="$0"
    fi

    cp -f "$source_script" \
        "$STATE_DIR/warp-masque-relay.sh"

    chmod 700 \
        "$STATE_DIR/warp-masque-relay.sh"
}

# ============================================================
# Synology startup
# ============================================================

create_synology_startup() {

    [[ "$SYSTEM" == "synology" ]] || return 0

    install_script_copy

    mkdir -p "$(dirname "$DSM_RC")"

    cat > "$DSM_RC" <<'EOF'
#!/bin/sh

SCRIPT="/etc/warp-masque-relay/warp-masque-relay.sh"

case "$1" in
    start)
        [ -x "$SCRIPT" ] && "$SCRIPT" start
        ;;
    stop)
        [ -x "$SCRIPT" ] && "$SCRIPT" stop
        ;;
    restart)
        [ -x "$SCRIPT" ] && "$SCRIPT" restart
        ;;
    *)
        exit 1
        ;;
esac

exit 0
EOF

    chmod +x "$DSM_RC"
}

# ============================================================
# Generic startup
# ============================================================

create_generic_startup() {

    if [[ "$SYSTEM" == "synology" ]]; then
        create_synology_startup
        return
    fi

    if command_exists systemctl; then
        return
    fi

    if [[ -f /etc/rc.local ]]; then

        if ! grep -q \
            "/etc/warp-masque-relay/warp-masque-relay.sh start" \
            /etc/rc.local 2>/dev/null; then

            sed -i \
                '/^exit 0/i /etc/warp-masque-relay/warp-masque-relay.sh start >/dev/null 2>\&1' \
                /etc/rc.local || true
        fi
    fi
}

# ============================================================
# Apply rules
# ============================================================

apply_rules() {

    case "$FIREWALL" in

        nftables)

            create_nft_rules
            load_nft_rules

            if command_exists systemctl; then
                create_nft_systemd_service
            else
                create_nft_startup_fallback
            fi

            ;;

        iptables)

            create_iptables_rules
            create_generic_startup

            ;;

        *)

            die "未知防火墙类型：$FIREWALL"
            ;;
    esac
}

# ============================================================
# Remove nft
# ============================================================

remove_nft_rules() {

    if command_exists systemctl; then

        systemctl disable --now \
            warp-masque-relay.service \
            >/dev/null 2>&1 || true

        rm -f "$NFT_SERVICE"

        systemctl daemon-reload \
            >/dev/null 2>&1 || true
    fi

    if command_exists nft; then

        NFT_BIN="$(command -v nft)"

        "$NFT_BIN" delete table ip warp_masque_relay \
            >/dev/null 2>&1 || true

        "$NFT_BIN" delete table ip6 warp_masque_relay6 \
            >/dev/null 2>&1 || true
    fi

    rm -f "$NFT_V4_FILE"
    rm -f "$NFT_V6_FILE"
}

# ============================================================
# Remove startup
# ============================================================

remove_startup() {

    rm -f "$DSM_RC"

    rm -f /etc/rc.d/S99warp-masque-relay

    if [[ -f /etc/rc.local ]]; then

        sed -i \
            '\#/etc/warp-masque-relay/warp-masque-relay.sh start#d' \
            /etc/rc.local \
            2>/dev/null || true
    fi
}

# ============================================================
# Status
# ============================================================

status() {

    detect_system
    detect_firewall

    echo
    echo "=========================================="
    echo " WARP MASQUE Relay Status"
    echo "=========================================="
    echo

    echo "System       : $SYSTEM"
    echo "Version      : $VERSION_INFO"
    echo "Kernel       : $KERNEL"
    echo "Architecture : $ARCH"
    echo "Firewall     : $FIREWALL"

    echo

    if [[ -f "$CONFIG_FILE" ]]; then

        # shellcheck disable=SC1090
        source "$CONFIG_FILE"

        echo "IPv4 Endpoint : ${CF_IPV4}:${CF_PORT}"

        if [[ -n "${CF_IPV6:-}" ]]; then
            echo "IPv6 Endpoint : [${CF_IPV6}]:${CF_PORT}"
        else
            echo "IPv6 Endpoint : DISABLED"
        fi

        echo "Relay Port    : ${LISTEN_PORT}"

    else

        echo "配置          : 未安装"
    fi

    echo

    if [[ "$FIREWALL" == "nftables" ]]; then

        NFT_BIN="$(command -v nft || true)"

        echo "------------------------------------------"
        echo " nftables IPv4"
        echo "------------------------------------------"

        if [[ -n "$NFT_BIN" ]]; then

            "$NFT_BIN" list table ip warp_masque_relay \
                2>/dev/null ||
                echo "IPv4 Relay table 不存在"

        else

            echo "nft 不存在"
        fi

        echo
        echo "------------------------------------------"
        echo " nftables IPv6"
        echo "------------------------------------------"

        if [[ -n "$NFT_BIN" ]]; then

            "$NFT_BIN" list table ip6 warp_masque_relay6 \
                2>/dev/null ||
                echo "IPv6 Relay table 不存在"
        fi

    else

        echo "------------------------------------------"
        echo " iptables WARP rules"
        echo "------------------------------------------"

        iptables -t nat -S 2>/dev/null |
            grep WARP ||
            true

        iptables -S FORWARD 2>/dev/null |
            grep WARP ||
            true

        echo
        echo "------------------------------------------"
        echo " ip6tables WARP rules"
        echo "------------------------------------------"

        if command_exists ip6tables; then

            ip6tables -t nat -S 2>/dev/null |
                grep WARP ||
                true

            ip6tables -S FORWARD 2>/dev/null |
                grep WARP ||
                true
        fi
    fi

    echo
    echo "------------------------------------------"
    echo " Forwarding"
    echo "------------------------------------------"

    sysctl net.ipv4.ip_forward \
        2>/dev/null || true

    sysctl net.ipv6.conf.all.forwarding \
        2>/dev/null || true

    echo
}

# ============================================================
# Test
# ============================================================

test_relay() {

    [[ -f "$CONFIG_FILE" ]] ||
        die "没有找到 Relay 配置，请先 install。"

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    detect_firewall

    echo
    echo "=========================================="
    echo " WARP MASQUE Relay Test"
    echo "=========================================="
    echo

    # --------------------------------------------------------
    # TCP / UDP local port
    # --------------------------------------------------------

    echo "[1] 本机端口检查"
    echo

    if command_exists ss; then

        ss -lnt 2>/dev/null |
            grep -E ":${LISTEN_PORT}[[:space:]]" ||
            echo "TCP ${LISTEN_PORT} 没有本地 LISTEN（DNAT 模式正常）"

        ss -lnu 2>/dev/null |
            grep -E ":${LISTEN_PORT}[[:space:]]" ||
            echo "UDP ${LISTEN_PORT} 没有本地 LISTEN（DNAT 模式正常）"
    fi

    # --------------------------------------------------------
    # IPv4 route
    # --------------------------------------------------------

    echo
    echo "[2] Cloudflare IPv4 路由"

    if command_exists ip; then
        ip -4 route get "$CF_IPV4" \
            2>/dev/null ||
            echo "IPv4 路由失败"
    fi

    # --------------------------------------------------------
    # IPv6 route
    # --------------------------------------------------------

    if [[ -n "$CF_IPV6" ]]; then

        echo
        echo "[3] Cloudflare IPv6 路由"

        if command_exists ip; then

            ip -6 route get "$CF_IPV6" \
                2>/dev/null ||
                echo "没有 IPv6 到 ${CF_IPV6} 的有效路由"
        fi
    fi

    # --------------------------------------------------------
    # TCP endpoint
    # --------------------------------------------------------

    echo
    echo "[4] TCP ${CF_IPV4}:${CF_PORT}"

    if command_exists timeout; then

        if timeout 5 bash -c \
            "exec 3<>/dev/tcp/${CF_IPV4}/${CF_PORT}" \
            >/dev/null 2>&1; then

            echo "TCP IPv4 Endpoint: OK"

        else

            echo "TCP IPv4 Endpoint: FAILED"
        fi

    else

        echo "系统没有 timeout，跳过 TCP 测试。"
    fi

    # --------------------------------------------------------
    # nft / iptables counters
    # --------------------------------------------------------

    echo
    echo "[5] 当前 Relay 规则"

    if [[ "$FIREWALL" == "nftables" ]]; then

        NFT_BIN="$(command -v nft || true)"

        if [[ -n "$NFT_BIN" ]]; then

            "$NFT_BIN" list table ip warp_masque_relay \
                2>/dev/null || true

            if [[ -n "$CF_IPV6" ]]; then

                "$NFT_BIN" list table ip6 warp_masque_relay6 \
                    2>/dev/null || true
            fi
        fi

    else

        iptables -t nat -S 2>/dev/null |
            grep WARP ||
            true

        if command_exists ip6tables; then

            ip6tables -t nat -S 2>/dev/null |
                grep WARP ||
                true
        fi
    fi

    echo
    echo "=========================================="
    echo " Test 完成"
    echo "=========================================="
    echo
    echo "注意："
    echo "TCP 测试只能验证 TCP Endpoint。"
    echo "UDP / MASQUE 最终应通过实际客户端连接测试。"
    echo
}

# ============================================================
# Install
# ============================================================

install_relay() {

    require_root

    detect_system
    detect_firewall

    echo
    echo "=========================================="
    echo " 系统检测"
    echo "=========================================="
    echo

    echo "系统       : $SYSTEM"
    echo "版本       : $VERSION_INFO"
    echo "Kernel     : $KERNEL"
    echo "架构       : $ARCH"
    echo "Firewall   : $FIREWALL"

    echo

    install_dependencies

    detect_firewall

    input_configuration

    show_configuration

    echo

    read -r -p \
        "确认安装 Relay？ [Y/n]: " \
        CONFIRM

    case "${CONFIRM:-Y}" in
        y|Y|yes|YES)
            ;;
        *)
            echo "已取消。"
            exit 0
            ;;
    esac

    echo

    log "开始安装..."

    mkdir -p "$STATE_DIR"

    save_configuration

    enable_forwarding

    install_script_copy

    apply_rules

    chmod 700 "$STATE_DIR"

    if [[ "$SYSTEM" == "synology" ]]; then
        create_synology_startup
    fi

    echo
    echo "=========================================="
    echo " Relay 安装完成"
    echo "=========================================="
    echo

    echo "系统          : $SYSTEM"
    echo "Firewall      : $FIREWALL"

    echo
    echo "IPv4 Relay:"
    echo "  ${LISTEN_PORT}"
    echo "      ↓"
    echo "  ${CF_IPV4}:${CF_PORT}"

    if [[ -n "$CF_IPV6" ]]; then

        echo
        echo "IPv6 Relay:"
        echo "  [${LISTEN_PORT}]"
        echo "      ↓"
        echo "  [${CF_IPV6}]:${CF_PORT}"
    fi

    echo
    echo "配置文件:"
    echo "  $CONFIG_FILE"

    echo
    echo "查看状态:"
    echo "  $0 status"

    echo
    echo "测试:"
    echo "  $0 test"

    echo
    echo "=========================================="
}

# ============================================================
# Uninstall
# ============================================================

uninstall_relay() {

    require_root

    detect_system
    detect_firewall

    echo
    echo "=========================================="
    echo " 卸载 WARP MASQUE Relay"
    echo "=========================================="
    echo

    read -r -p \
        "确认卸载？ [y/N]: " \
        CONFIRM

    case "${CONFIRM:-N}" in
        y|Y|yes|YES)
            ;;
        *)
            echo "已取消。"
            exit 0
            ;;
    esac

    if [[ "$FIREWALL" == "nftables" ]]; then
        remove_nft_rules
    fi

    if [[ "$FIREWALL" == "iptables" ]]; then
        remove_iptables_rules
    fi

    remove_startup

    rm -f /etc/sysctl.d/99-warp-masque-relay.conf

    # 只删除本脚本设置的 forwarding，
    # 不主动关闭系统 forwarding，避免影响其它服务。

    if command_exists sysctl; then

        sysctl --system \
            >/dev/null 2>&1 || true
    fi

    rm -rf "$STATE_DIR"

    echo
    echo "Relay 规则已经删除。"
    echo "Relay 卸载完成。"
    echo
}

# ============================================================
# Start
# ============================================================

start_relay() {

    require_root

    [[ -f "$CONFIG_FILE" ]] ||
        die "Relay 尚未安装。"

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [[ "$FIREWALL" == "nftables" ]]; then

        NFT_BIN="$(command -v nft || true)"

        [[ -n "$NFT_BIN" ]] ||
            die "系统没有找到 nft。"

        create_nft_rules
        load_nft_rules

    else

        create_iptables_rules
    fi

    echo "Relay 已启动。"
}

# ============================================================
# Stop
# ============================================================

stop_relay() {

    require_root

    detect_firewall

    if [[ "$FIREWALL" == "nftables" ]]; then

        NFT_BIN="$(command -v nft || true)"

        if [[ -n "$NFT_BIN" ]]; then
            delete_nft_tables
        fi

    else

        remove_iptables_rules
    fi

    echo "Relay 已停止。"
}

# ============================================================
# Restart
# ============================================================

restart_relay() {

    require_root

    stop_relay
    start_relay
}

# ============================================================
# Help
# ============================================================

usage() {

    cat <<EOF

Cloudflare WARP MASQUE Relay ${VERSION}

用法:

  $0
  $0 install

  $0 status
  $0 test

  $0 start
  $0 stop
  $0 restart

  $0 uninstall

命令:

  install      安装 Relay
  status       查看状态
  test         测试 Relay
  start        启动 Relay
  stop         停止 Relay
  restart      重启 Relay
  uninstall    卸载 Relay

默认配置:

  IPv4 Endpoint : ${DEFAULT_CF_IPV4}:${DEFAULT_CF_PORT}
  IPv6 Endpoint : [${DEFAULT_CF_IPV6}]:${DEFAULT_CF_PORT}
  Relay Port    : ${DEFAULT_LISTEN_PORT}

EOF
}

# ============================================================
# Main
# ============================================================

main() {

    case "${1:-install}" in

        install)
            install_relay
            ;;

        status)
            status
            ;;

        test)
            test_relay
            ;;

        start)
            start_relay
            ;;

        stop)
            stop_relay
            ;;

        restart)
            restart_relay
            ;;

        uninstall)
            uninstall_relay
            ;;

        -h|--help|help)
            usage
            ;;

        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"