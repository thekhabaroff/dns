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
  -i, --interface <iface> Обработать только этот интерфейс (можно
                            повторять или списком через запятую).
                            По умолчанию берём все интерфейсы
                            с default route (IPv4 + IPv6).
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
EXPLICIT_IFACES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--provider) PROVIDER="${2:-}"; shift 2 ;;
        -i|--interface)
            # Поддерживаем как `-i eth0 -i eth1`, так и `-i eth0,eth1`.
            IFS=', ' read -r -a __split <<< "${2:-}"
            for __it in "${__split[@]}"; do
                [ -n "$__it" ] && EXPLICIT_IFACES+=("$__it")
            done
            unset __split __it
            shift 2 ;;
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

# Вернуть все уникальные интерфейсы с default-маршрутом (IPv4 + IPv6),
# по одному на строку. На multi-WAN машинах их может быть >1 —
# обрабатывать нужно все, иначе на необработанных останутся DHCP-DNS.
detect_interfaces() {
    {
        ip -4 route show default 2>/dev/null | awk '/^default/ {print $5}'
        ip -6 route show default 2>/dev/null | awk '/^default/ {print $5}'
    } | awk 'NF && !seen[$0]++'
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

# Отключить чужие drop-in'ы в /etc/systemd/resolved.conf.d/, которые
# содержат DNS=/FallbackDNS= и потому МЕРДЖАТСЯ с нашим основным конфигом.
# Файлы переименовываются (а не удаляются), чтобы --rollback мог их вернуть.
disable_conflicting_resolved_dropins() {
    local dir="/etc/systemd/resolved.conf.d"
    [ -d "$dir" ] || return 0
    local f base
    for f in "$dir"/*.conf; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        # nofallback.conf — артефакт прежней версии, удаляем безусловно ниже.
        [ "$base" = "nofallback.conf" ] && continue
        if grep -Eq '^[[:space:]]*(DNS|FallbackDNS)=' "$f"; then
            mv -f "$f" "$f.disabled-by-dns-sh"
            echo -e "${YELLOW}⚠ Отключён конфликтующий drop-in: $f→.disabled-by-dns-sh${NC}"
        fi
    done
}

# Восстановить drop-in'ы, которые мы переименовали.
restore_resolved_dropins() {
    local dir="/etc/systemd/resolved.conf.d"
    [ -d "$dir" ] || return 0
    local f orig
    for f in "$dir"/*.disabled-by-dns-sh; do
        [ -f "$f" ] || continue
        orig="${f%.disabled-by-dns-sh}"
        mv -f "$f" "$orig"
        echo -e "${GREEN}✓ Восстановлен drop-in: $orig${NC}"
    done
}

# Найти .network-файл, по которому systemd-networkd сконфигурировал интерфейс.
find_networkd_unit() {
    local iface="$1" netfile=""
    if command -v networkctl >/dev/null 2>&1; then
        netfile=$(networkctl status "$iface" 2>/dev/null \
            | awk -F': +' '/Network File:/ {print $2; exit}')
    fi
    if [ -z "$netfile" ] || [ ! -f "$netfile" ]; then
        netfile=$(grep -lE "^Name=$iface([[:space:]]|$)" \
            /run/systemd/network/*.network /etc/systemd/network/*.network \
            2>/dev/null | head -1)
    fi
    echo "$netfile"
}

# Создать drop-in для .network-юнита заданного интерфейса,
# запрещающий принимать DNS от DHCP/RA. Срабатывает только если
# активен systemd-networkd. NetworkManager ловится отдельно
# (no-dns.conf). Возвращает 0, если drop-in создан, 1 иначе.
configure_networkd_no_dns() {
    local iface="$1"
    if ! command -v systemctl >/dev/null 2>&1; then return 1; fi
    if ! systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        return 1
    fi
    local netfile
    netfile="$(find_networkd_unit "$iface")"
    if [ -z "$netfile" ]; then
        echo -e "${YELLOW}⚠ systemd-networkd активен, но .network для $iface не найден — UseDNS=no не применяю на $iface.${NC}"
        return 1
    fi
    local base conf_dir
    base="$(basename "$netfile")"
    conf_dir="/etc/systemd/network/${base}.d"
    mkdir -p "$conf_dir"
    cat > "$conf_dir/no-dhcp-dns.conf" <<'EOF'
# Создан dns.sh: запрещает DHCP/RA подсовывать свои DNS.
[DHCP]
UseDNS=no
[IPv6AcceptRA]
UseDNS=no
EOF
    echo -e "${GREEN}✓ systemd-networkd ($iface): $conf_dir/no-dhcp-dns.conf → UseDNS=no.${NC}"
    return 0
}

# Удалить наши systemd-networkd drop-in'ы (для --rollback).
remove_networkd_no_dns() {
    local d removed=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ -f "$d/no-dhcp-dns.conf" ]; then
            rm -f "$d/no-dhcp-dns.conf"
            rmdir "$d" 2>/dev/null || true
            echo -e "${GREEN}✓ Удалён $d/no-dhcp-dns.conf${NC}"
            removed=1
        fi
    done < <(find /etc/systemd/network -maxdepth 1 -type d -name '*.network.d' 2>/dev/null)
    if [ "$removed" = "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl restart systemd-networkd 2>/dev/null || true
    fi
}

# Показать сводку, чтобы не было сюрпризов «откуда взялся 8.8.8.8».
print_dns_layout() {
    echo -e "${CYAN}Конфиги, влияющие на DNS:${NC}"
    echo -e "  /etc/systemd/resolved.conf"
    if compgen -G "/etc/systemd/resolved.conf.d/*.conf" >/dev/null 2>&1; then
        local f
        for f in /etc/systemd/resolved.conf.d/*.conf; do
            echo -e "  $f"
        done
    fi
    if compgen -G "/etc/systemd/resolved.conf.d/*.disabled-by-dns-sh" >/dev/null 2>&1; then
        local f
        for f in /etc/systemd/resolved.conf.d/*.disabled-by-dns-sh; do
            echo -e "  $f  ${YELLOW}(отключён)${NC}"
        done
    fi
    if compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1; then
        local f
        for f in /etc/netplan/*.yaml; do
            if grep -qE '^[[:space:]]*nameservers[[:space:]]*:' "$f" 2>/dev/null; then
                echo -e "  $f  ${YELLOW}(содержит nameservers:)${NC}"
            fi
        done
    fi
    if command -v systemctl >/dev/null 2>&1 \
            && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        local iface netfile base
        for iface in "$@"; do
            netfile="$(find_networkd_unit "$iface")"
            if [ -n "$netfile" ]; then
                echo -e "  $netfile"
                base="$(basename "$netfile")"
                if [ -f "/etc/systemd/network/${base}.d/no-dhcp-dns.conf" ]; then
                    echo -e "  /etc/systemd/network/${base}.d/no-dhcp-dns.conf"
                fi
            fi
        done
    fi
}

# Предупредить, если netplan описывает интерфейсы, которых в
# системе нет (или не описывает реальные). Типичный кейс —
# cloud-image netplan с `enp1s0`, а реальные интерфейсы ens3/ens4.
warn_netplan_iface_mismatch() {
    [ "$#" -ge 1 ] || return 0
    compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1 || return 0
    local netplan_ifaces
    # Извлекаем имена из секций ethernets:/wifis:/bridges: (set-name или ключ).
    # Парсим netplan YAML: ищем ключи под секциями ethernets/wifis/bridges/bonds/vlans
    # и значения set-name (последние имеют приоритет, если присутствуют).
    netplan_ifaces=$(awk '
        function get_indent(s,    i) { for (i=1;i<=length(s);i++) if (substr(s,i,1)!=" ") return i-1; return length(s) }
        /^[[:space:]]*(ethernets|wifis|bridges|bonds|vlans):[[:space:]]*$/ {
            block_indent = get_indent($0); in_block = 1; child_indent = -1; next
        }
        in_block {
            if (NF == 0) next
            line_indent = get_indent($0)
            if (line_indent <= block_indent) { in_block = 0; next }
            if (child_indent < 0) child_indent = line_indent
            if (line_indent == child_indent && /:[[:space:]]*$/) {
                key = $1; sub(/:/, "", key); gsub(/["\047]/, "", key); print key
            }
            if (/^[[:space:]]+set-name:[[:space:]]*/) {
                val = $2; gsub(/["\047]/, "", val); if (val != "") print val
            }
        }
    ' /etc/netplan/*.yaml 2>/dev/null | awk 'NF && !seen[$0]++')
    [ -n "$netplan_ifaces" ] || return 0
    local iface missing=()
    for iface in "$@"; do
        if ! grep -qx "$iface" <<< "$netplan_ifaces"; then
            missing+=("$iface")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "${YELLOW}⚠ netplan не описывает интерфейсы: ${missing[*]}.${NC}"
        echo -e "${YELLOW}  netplan видит: $(echo "$netplan_ifaces" | tr '\n' ' ')."
        echo -e "  Сеть на этих интерфейсах поднимает кто-то другой (cloud-init/ifupdown/вручную),${NC}"
        echo -e "${YELLOW}  поэтому networkd UseDNS=no drop-in может не примениться — per-link DNS сбросится при DHCP-renew/ребуте.${NC}"
    fi
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

    restore_resolved_dropins
    remove_networkd_no_dns

    cat > /etc/systemd/resolved.conf <<'EOF'
# Восстановлено dns.sh --rollback (минимальный дефолт).
[Resolve]
EOF
    echo -e "${GREEN}✓ /etc/systemd/resolved.conf сброшен к дефолтам.${NC}"

    if command -v resolvectl >/dev/null 2>&1; then
        local iface
        while IFS= read -r iface; do
            [ -n "$iface" ] || continue
            resolvectl revert "$iface" 2>/dev/null || true
        done < <(detect_interfaces)
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
INTERFACES=()
if [ "${#EXPLICIT_IFACES[@]}" -gt 0 ]; then
    INTERFACES=("${EXPLICIT_IFACES[@]}")
else
    while IFS= read -r __iface; do
        [ -n "$__iface" ] && INTERFACES+=("$__iface")
    done < <(detect_interfaces)
    unset __iface
fi

if [ "${#INTERFACES[@]}" -eq 0 ]; then
    echo -e "${RED}Ошибка: не удалось определить активные интерфейсы по таблице маршрутизации.${NC}"
    echo -e "${RED}       Проверь: ip -4 route show default ; ip -6 route show default${NC}"
    echo -e "${RED}       Или укажи явно: $SCRIPT_NAME -i <iface>${NC}"
    exit 1
fi

# Первый интерфейс считаем «основным» — используется в сообщениях.
INTERFACE="${INTERFACES[0]}"
if [ "${#INTERFACES[@]}" -eq 1 ]; then
    echo -e "${CYAN}Активный интерфейс: ${GREEN}$INTERFACE${NC}"
else
    echo -e "${CYAN}Активные интерфейсы (default route): ${GREEN}${INTERFACES[*]}${NC}"
fi

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
warn_netplan_iface_mismatch "${INTERFACES[@]}"

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

# Step 3: единственный источник правды — /etc/systemd/resolved.conf.
# Чужие drop-in'ы в /etc/systemd/resolved.conf.d/ с DNS=/FallbackDNS=
# мерджатся с нашим конфигом, поэтому мы их временно отключаем
# (переименовываем; --rollback вернёт обратно). nofallback.conf —
# артефакт прежней версии скрипта, удаляем безусловно.
rm -f /etc/systemd/resolved.conf.d/nofallback.conf
disable_conflicting_resolved_dropins

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

# Step 4: запретить systemd-networkd принимать DNS из DHCP/RA на каждом интерфейсе.
for IFACE in "${INTERFACES[@]}"; do
    configure_networkd_no_dns "$IFACE" || true
done
# Рестарт networkd один раз после всех drop-in'ов.
if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    systemctl restart systemd-networkd 2>/dev/null || true
fi

# Step 5: применить новые настройки networkd к УЖЕ работающим линкам.
# `systemctl restart systemd-networkd` сам по себе не перенастраивает
# активные интерфейсы — старая DHCP-аренда и кэш per-link DNS остаются.
# `networkctl reload && networkctl reconfigure` форсируют пере-сборку.
if command -v networkctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    networkctl reload 2>/dev/null || true
    for IFACE in "${INTERFACES[@]}"; do
        if networkctl reconfigure "$IFACE" 2>/dev/null; then
            echo -e "${GREEN}✓ networkctl reconfigure $IFACE.${NC}"
        fi
    done
fi

# Step 6: рестарт systemd-resolved и принудительная установка per-link DNS.
# Тонкий момент: netplan/systemd-networkd при наличии секции `nameservers:`
# в /etc/netplan/*.yaml пишут [Network] DNS=... в .network-юнит, и
# `resolvectl revert` сбрасывает per-link DNS именно к этим значениям —
# то есть к netplan-овским, а не к выбранным нами. Так как у активного
# интерфейса +DefaultRoute, per-link DNS имеет приоритет над Global,
# и фактический резолв идёт через netplan-овские DNS.
#
# Поэтому: revert (сброс кэша + старой DHCP-аренды), затем `resolvectl dns`
# с нашими серверами — это переопределяет per-link DNS принудительно,
# независимо от netplan. Сохраняется до следующего reconfigure линка
# (например, ребута или `netplan apply`).
systemctl restart systemd-resolved
echo -e "${GREEN}✓ systemd-resolved перезапущен.${NC}"

if command -v resolvectl >/dev/null 2>&1; then
    for IFACE in "${INTERFACES[@]}"; do
        resolvectl revert "$IFACE" 2>/dev/null || true
        if resolvectl dns "$IFACE" "$DNS1" "$DNS2" 2>/dev/null; then
            echo -e "${GREEN}✓ Per-link DNS на $IFACE: $DNS1 $DNS2.${NC}"
        else
            echo -e "${YELLOW}⚠ Не удалось задать per-link DNS на $IFACE через resolvectl.${NC}"
        fi
    done
    resolvectl flush-caches 2>/dev/null || true
fi

# Step 7: stub-резолвер
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
resolvectl status 2>/dev/null | grep -E "DNS Servers|Fallback" | head -8 || true

echo ""
echo -e "${CYAN}Тест резолвинга ($TEST_DOMAIN):${NC}"
test_resolve "$TEST_DOMAIN" || echo -e "${RED}⚠ Не удалось проверить резолвинг.${NC}"

echo ""
print_dns_layout "${INTERFACES[@]}"

echo ""
echo -e "${GREEN}Готово! Установлен: $LABEL ($DNS1, $DNS2)${NC}"
if [ "$USE_DOT" -eq 1 ] && [[ "$DOT_LINE" == *opportunistic* ]]; then
    echo -e "${GREEN}  DNS-over-TLS: opportunistic, DNSSEC: allow-downgrade.${NC}"
fi
echo -e "${CYAN}Для отката: sudo $SCRIPT_NAME --rollback${NC}"
