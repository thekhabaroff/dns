#!/usr/bin/env bash
# ============================================================
# dns.sh — Смена DNS на Ubuntu VPS
# ============================================================

set -euo pipefail

RED="\e[91m"
GREEN="\e[92m"
YELLOW="\e[93m"
CYAN="\e[96m"
NC="\e[0m"

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  -p, --provider <name>   Выбрать DNS-провайдер без меню:
                            yandex | cloudflare | google | quad9
  -y, --yes               Не запрашивать подтверждений (неинтерактивный режим).
      --dot               Включить DNS-over-TLS + DNSSEC=allow-downgrade
                            (поддерживается для cloudflare/google/quad9).
      --rollback          Откатить изменения, сделанные этим скриптом.
  -h, --help              Показать это сообщение.

Примеры:
  sudo $SCRIPT_NAME                          # интерактивный режим
  sudo $SCRIPT_NAME -p cloudflare -y         # без меню
  sudo $SCRIPT_NAME -p quad9 --dot -y        # с DNS-over-TLS
  sudo $SCRIPT_NAME --rollback               # откат
EOF
}

PROVIDER=""
ASSUME_YES=0
USE_DOT=0
ROLLBACK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--provider) PROVIDER="${2:-}"; shift 2 ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        --dot)         USE_DOT=1; shift ;;
        --rollback)    ROLLBACK=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo -e "${RED}Неизвестный аргумент: $1${NC}"; usage; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запусти скрипт с правами root: sudo bash $SCRIPT_NAME${NC}"
    exit 1
fi

# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------
prompt_yes() {
    local q="$1" ans=""
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    read -rp "$q" ans || true
    [[ "$ans" =~ ^[Yy]$ ]]
}

detect_interface() {
    local iface=""
    iface=$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    if [ -z "$iface" ]; then
        iface=$(ip -6 route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    echo "$iface"
}

warn_netplan_cloudinit() {
    if compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1; then
        local files
        files=$(grep -lE '^[[:space:]]*nameservers[[:space:]]*:' /etc/netplan/*.yaml 2>/dev/null || true)
        if [ -n "$files" ]; then
            echo -e "${YELLOW}⚠ Найдены netplan-конфиги с секцией nameservers:${NC}"
            while IFS= read -r f; do
                printf '    %s\n' "$f"
            done <<< "$files"
            echo -e "${YELLOW}  Они могут перетереть DNS при следующем 'netplan apply' или ребуте.${NC}"
            echo -e "${YELLOW}  Удали/закомментируй секцию nameservers вручную, если хочешь зафиксировать DNS навсегда.${NC}"
        fi
    fi

    if [ -d /etc/cloud ] && command -v cloud-init >/dev/null 2>&1; then
        if [ ! -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ]; then
            echo -e "${YELLOW}⚠ Установлен cloud-init — он может перегенерить сеть/DNS при ребуте.${NC}"
            if prompt_yes "Отключить управление сетью cloud-init (создать 99-disable-network-config.cfg)? [y/N] "; then
                cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
                echo -e "${GREEN}✓ cloud-init network management отключён.${NC}"
            else
                echo -e "${YELLOW}  Пропускаю — cloud-init может перетереть DNS при ребуте.${NC}"
            fi
        fi
    fi
}

test_resolve() {
    local domain="$1"
    if command -v resolvectl >/dev/null 2>&1; then
        if resolvectl query "$domain" 2>/dev/null | sed -n '1,5p'; then
            return 0
        fi
    fi
    if command -v dig >/dev/null 2>&1; then
        local out
        out=$(dig +short "$domain" 2>/dev/null || true)
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    fi
    if command -v getent >/dev/null 2>&1; then
        if getent hosts "$domain"; then
            return 0
        fi
    fi
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup "$domain"; then
            return 0
        fi
    fi
    echo -e "${YELLOW}⚠ Нет утилит для проверки (resolvectl/dig/getent/nslookup).${NC}"
    return 1
}

is_immutable() {
    local f="$1"
    lsattr "$f" 2>/dev/null | awk '{print $1}' | grep -q i
}

# ------------------------------------------------------------
# rollback
# ------------------------------------------------------------
rollback() {
    echo -e "${YELLOW}Откат изменений…${NC}"

    if [ -f /etc/NetworkManager/conf.d/no-dns.conf ]; then
        rm -f /etc/NetworkManager/conf.d/no-dns.conf
        echo -e "${GREEN}✓ Удалён /etc/NetworkManager/conf.d/no-dns.conf.${NC}"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart NetworkManager 2>/dev/null || true
        fi
    fi

    if [ -f /etc/dhcp/dhclient.conf ]; then
        sed -i -E '/^[[:space:]]*supersede[[:space:]]+domain-name-servers/d' /etc/dhcp/dhclient.conf
        echo -e "${GREEN}✓ supersede-строки удалены из /etc/dhcp/dhclient.conf.${NC}"
    fi

    rm -f /etc/systemd/resolved.conf.d/nofallback.conf
    rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

    cat > /etc/systemd/resolved.conf <<'EOF'
# Восстановлено dns.sh --rollback (минимальный дефолт).
[Resolve]
EOF
    echo -e "${GREEN}✓ /etc/systemd/resolved.conf сброшен к дефолтам.${NC}"

    local iface
    iface="$(detect_interface)"
    if [ -n "$iface" ] && command -v resolvectl >/dev/null 2>&1; then
        resolvectl revert "$iface" 2>/dev/null || true
    fi

    systemctl restart systemd-resolved 2>/dev/null || true

    chattr -i /etc/resolv.conf 2>/dev/null || true
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    echo -e "${GREEN}Готово. Откат завершён.${NC}"
}

if [ "$ROLLBACK" -eq 1 ]; then
    rollback
    exit 0
fi

# ------------------------------------------------------------
# main
# ------------------------------------------------------------
INTERFACE="$(detect_interface)"
if [ -z "$INTERFACE" ]; then
    echo -e "${RED}Ошибка: не удалось определить активный интерфейс по таблице маршрутизации.${NC}"
    echo -e "${RED}       Проверь: ip -4 route show default${NC}"
    exit 1
fi
echo -e "${CYAN}Активный интерфейс: ${GREEN}$INTERFACE${NC}"

# Map provider → DNS values
set_provider() {
    local key="${1,,}"
    case "$key" in
        1|yandex)
            DNS1="77.88.8.8";  DNS2="77.88.8.1"
            LABEL="Yandex DNS"; TEST_DOMAIN="dns.yandex.ru"; PROVIDER_KEY="yandex" ;;
        2|cloudflare|cf)
            DNS1="1.1.1.1";    DNS2="1.0.0.1"
            LABEL="Cloudflare DNS"; TEST_DOMAIN="cloudflare.com"; PROVIDER_KEY="cloudflare" ;;
        3|google)
            DNS1="8.8.8.8";    DNS2="8.8.4.4"
            LABEL="Google DNS"; TEST_DOMAIN="dns.google"; PROVIDER_KEY="google" ;;
        4|quad9)
            DNS1="9.9.9.9";    DNS2="149.112.112.112"
            LABEL="Quad9 DNS"; TEST_DOMAIN="dns.quad9.net"; PROVIDER_KEY="quad9" ;;
        *) return 1 ;;
    esac
    return 0
}

if [ -z "$PROVIDER" ]; then
    echo ""
    echo -e "${YELLOW}Выбери DNS-провайдер:${NC}"
    echo -e "${RED}1.${NC} Yandex DNS           (77.88.8.8,   77.88.8.1)"
    echo -e "${RED}2.${NC} Cloudflare DNS       (1.1.1.1,     1.0.0.1)"
    echo -e "${RED}3.${NC} Google DNS           (8.8.8.8,     8.8.4.4)"
    echo -e "${RED}4.${NC} Quad9 DNS            (9.9.9.9,     149.112.112.112)"
    echo ""
    read -rp "Введи номер (1-4): " PROVIDER
fi

if ! set_provider "$PROVIDER"; then
    echo -e "${RED}Неверный выбор: '$PROVIDER'.${NC}"
    exit 1
fi

# DNS-over-TLS / DNSSEC
DOT_LINE="DNSOverTLS=no"
DNSSEC_LINE="DNSSEC=no"
if [ "$USE_DOT" -eq 1 ]; then
    case "$PROVIDER_KEY" in
        cloudflare|quad9|google)
            DOT_LINE="DNSOverTLS=opportunistic"
            DNSSEC_LINE="DNSSEC=allow-downgrade"
            ;;
        *)
            echo -e "${YELLOW}⚠ DoT для $LABEL не поддерживается, оставляю выключенным.${NC}"
            ;;
    esac
fi

echo ""
echo -e "${YELLOW}Применяю: ${GREEN}$LABEL${YELLOW} → $DNS1, $DNS2${NC}"

# Step 0: предупредить про netplan/cloud-init и опционально отключить cloud-init network management
warn_netplan_cloudinit

# Step 1: NetworkManager
if command -v nmcli >/dev/null 2>&1; then
    mkdir -p /etc/NetworkManager/conf.d/
    cat > /etc/NetworkManager/conf.d/no-dns.conf <<EOF
[main]
dns=none
systemd-resolved=false
EOF
    echo -e "${GREEN}✓ NetworkManager не будет перезаписывать DNS.${NC}"
    systemctl restart NetworkManager 2>/dev/null || true
    sleep 1
else
    echo -e "${CYAN}NetworkManager не найден, пропускаем.${NC}"
fi

# Step 2: dhclient
DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
if [ -f "$DHCLIENT_CONF" ]; then
    if grep -Eq '^[[:space:]]*supersede[[:space:]]+domain-name-servers' "$DHCLIENT_CONF"; then
        sed -i -E "s|^[[:space:]]*supersede[[:space:]]+domain-name-servers.*$|supersede domain-name-servers $DNS1, $DNS2;|" "$DHCLIENT_CONF"
    else
        echo "supersede domain-name-servers $DNS1, $DNS2;" >> "$DHCLIENT_CONF"
    fi
    echo -e "${GREEN}✓ dhclient зафиксирован на $DNS1, $DNS2.${NC}"
fi

# Step 3: сбросить per-link DNS на интерфейсе
if command -v resolvectl >/dev/null 2>&1; then
    if resolvectl revert "$INTERFACE" 2>/dev/null; then
        echo -e "${GREEN}✓ Per-link DNS сброшен на $INTERFACE.${NC}"
    else
        echo -e "${YELLOW}⚠ Не удалось сбросить per-link DNS на $INTERFACE.${NC}"
    fi
fi

# Step 4: единственный источник правды — /etc/systemd/resolved.conf
# (drop-in nofallback.conf удаляется, чтобы не было противоречий с FallbackDNS).
rm -f /etc/systemd/resolved.conf.d/nofallback.conf

cat > /etc/systemd/resolved.conf <<EOF
# Сгенерировано dns.sh ($LABEL).
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=$DNS1 $DNS2
$DNSSEC_LINE
$DOT_LINE
Cache=yes
EOF
echo -e "${GREEN}✓ /etc/systemd/resolved.conf обновлён.${NC}"

systemctl restart systemd-resolved
echo -e "${GREEN}✓ systemd-resolved перезапущен.${NC}"

# Step 5: stub-резолвер
if [ -e /etc/resolv.conf ] && is_immutable /etc/resolv.conf; then
    echo -e "${YELLOW}⚠ /etc/resolv.conf был immutable (chattr +i). Снимаю флаг.${NC}"
    echo -e "${YELLOW}  После замены на симлинк +i обратно не ставится — это ожидаемо.${NC}"
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
echo -e "${GREEN}✓ /etc/resolv.conf → stub-резолвер (127.0.0.53).${NC}"

# Verify
echo ""
echo -e "${YELLOW}Проверяю применённые DNS...${NC}"
sleep 1

echo -e "${CYAN}Глобальные DNS серверы:${NC}"
resolvectl status 2>/dev/null | grep -E "DNS Servers|Fallback" | head -4 || true

echo ""
echo -e "${CYAN}Тест резолвинга ($TEST_DOMAIN):${NC}"
test_resolve "$TEST_DOMAIN" || echo -e "${RED}⚠ Не удалось проверить резолвинг.${NC}"

echo ""
echo -e "${GREEN}Готово! Установлен: $LABEL ($DNS1, $DNS2)${NC}"
if [ "$USE_DOT" -eq 1 ] && [[ "$DOT_LINE" == *opportunistic* ]]; then
    echo -e "${GREEN}  DNS-over-TLS: opportunistic, DNSSEC: allow-downgrade.${NC}"
fi
echo -e "${CYAN}Для отката: sudo $SCRIPT_NAME --rollback${NC}"
