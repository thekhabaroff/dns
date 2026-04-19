#!/bin/bash

# ============================================================
# dns.sh — Смена DNS на Ubuntu VPS
# ============================================================

RED="\e[91m"
GREEN="\e[92m"
YELLOW="\e[93m"
CYAN="\e[96m"
NC="\e[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запусти скрипт с правами root: sudo bash dns.sh${NC}"
    exit 1
fi

# Определяем активный сетевой интерфейс
INTERFACE=$(ip -o link show | awk '/state UP/ {print $2}' | sed 's/:$//' | head -1)
if [ -z "$INTERFACE" ]; then
    echo -e "${RED}Ошибка: не удалось определить сетевой интерфейс.${NC}"
    exit 1
fi
echo -e "${CYAN}Активный интерфейс: ${GREEN}$INTERFACE${NC}"

# Выбор DNS
echo ""
echo -e "${YELLOW}Выбери DNS-провайдер:${NC}"
echo -e "${RED}1.${NC} Yandex DNS           (77.88.8.8,   77.88.8.1)"
echo -e "${RED}2.${NC} Cloudflare DNS       (1.1.1.1,     1.0.0.1)"
echo -e "${RED}3.${NC} Google DNS           (8.8.8.8,     8.8.4.4)"
echo -e "${RED}4.${NC} Quad9 DNS            (9.9.9.9,     149.112.112.112)"
echo ""
read -p "Введи номер (1-4): " choice

case $choice in
    1) DNS1="77.88.8.8";  DNS2="77.88.8.1";         LABEL="Yandex DNS";         TEST_DOMAIN="dns.yandex.ru"  ;;
    2) DNS1="1.1.1.1";    DNS2="1.0.0.1";           LABEL="Cloudflare DNS";     TEST_DOMAIN="cloudflare.com" ;;
    3) DNS1="8.8.8.8";    DNS2="8.8.4.4";           LABEL="Google DNS";         TEST_DOMAIN="dns.google"     ;;
    4) DNS1="9.9.9.9";    DNS2="149.112.112.112";   LABEL="Quad9 DNS";          TEST_DOMAIN="dns.quad9.net"  ;;
    *)
        echo -e "${RED}Неверный выбор.${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${YELLOW}Применяю: ${GREEN}$LABEL${YELLOW} → $DNS1, $DNS2${NC}"

# ============================================================
# Шаг 1: Отключаем DNS от NetworkManager (если установлен)
# ============================================================
if command -v nmcli >/dev/null 2>&1; then
    mkdir -p /etc/NetworkManager/conf.d/
    cat > /etc/NetworkManager/conf.d/no-dns.conf << EOF
[main]
dns=none
systemd-resolved=false
EOF
    echo -e "${GREEN}✓ NetworkManager не будет перезаписывать DNS.${NC}"
    systemctl reload NetworkManager 2>/dev/null || true
    sleep 1
else
    echo -e "${CYAN}NetworkManager не найден, пропускаем.${NC}"
fi

# ============================================================
# Шаг 2: Запрещаем DHCP-клиенту перезаписывать DNS
# ============================================================
DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
if [ -f "$DHCLIENT_CONF" ]; then
    if ! grep -q "supersede domain-name-servers" "$DHCLIENT_CONF"; then
        echo "supersede domain-name-servers $DNS1, $DNS2;" >> "$DHCLIENT_CONF"
    else
        sed -i "s/supersede domain-name-servers .*/supersede domain-name-servers $DNS1, $DNS2;/" "$DHCLIENT_CONF"
    fi
    echo -e "${GREEN}✓ dhclient зафиксирован на $DNS1, $DNS2.${NC}"
fi

# ============================================================
# Шаг 3: Убираем DNS провайдера с интерфейса
# ============================================================
resolvectl dns "$INTERFACE" "" 2>/dev/null \
    && echo -e "${GREEN}✓ DNS провайдера убран с интерфейса $INTERFACE.${NC}" \
    || echo -e "${YELLOW}⚠ Не удалось очистить DNS на интерфейсе.${NC}"

# ============================================================
# Шаг 4: Отключаем compile-time fallback дефолты через drop-in
# ============================================================
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/nofallback.conf << EOF
[Resolve]
FallbackDNS=
EOF

# ============================================================
# Шаг 5: Прописываем DNS в systemd-resolved
# ============================================================
cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=$DNS1 $DNS2
Domains=~.
DNSSEC=no
DNSOverTLS=no
Cache=yes
EOF
echo -e "${GREEN}✓ resolved.conf обновлён.${NC}"

systemctl restart systemd-resolved
echo -e "${GREEN}✓ systemd-resolved перезапущен.${NC}"

# ============================================================
# Шаг 6: Фиксируем resolv.conf на stub-резолвер
# ============================================================
chattr -i /etc/resolv.conf 2>/dev/null || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
echo -e "${GREEN}✓ /etc/resolv.conf → stub-резолвер (127.0.0.53).${NC}"

# ============================================================
# Проверка
# ============================================================
echo ""
echo -e "${YELLOW}Проверяю применённые DNS...${NC}"
sleep 1

echo -e "${CYAN}Глобальные DNS серверы:${NC}"
resolvectl status | grep -E "DNS Servers|Fallback" | head -4

echo ""
echo -e "${CYAN}Тест резолвинга ($TEST_DOMAIN):${NC}"
resolvectl query "$TEST_DOMAIN" 2>/dev/null | grep -E "$TEST_DOMAIN|via" \
    || nslookup "$TEST_DOMAIN"

echo ""
echo -e "${GREEN}Готово! Установлен: $LABEL ($DNS1, $DNS2)${NC}"