# dns.sh — смена DNS на Ubuntu VPS

Небольшой bash-скрипт, который переключает резолвер Ubuntu на один из публичных
DNS-провайдеров (Yandex / Cloudflare / Google / Quad9), не позволяя
NetworkManager и dhclient перетереть настройки.

## Установка

```shell
curl -fsSL https://raw.githubusercontent.com/thekhabaroff/dns/master/dns.sh \
  -o /usr/local/bin/dns && chmod +x /usr/local/bin/dns && sudo dns
```

## Использование

```shell
# Интерактивный режим: меню выбора провайдера
sudo dns

# Без меню
sudo dns -p cloudflare -y
sudo dns -p quad9 --dot -y      # с DNS-over-TLS + DNSSEC=allow-downgrade

# Откат всех изменений, сделанных скриптом
sudo dns --rollback

# Справка
dns --help
```

### Поддерживаемые провайдеры

| Ключ          | Серверы                              |
| ------------- | ------------------------------------ |
| `yandex`      | 77.88.8.8, 77.88.8.1                 |
| `cloudflare`  | 1.1.1.1, 1.0.0.1                     |
| `google`      | 8.8.8.8, 8.8.4.4                     |
| `quad9`       | 9.9.9.9, 149.112.112.112             |

## Что делает скрипт

1. Определяет интерфейс по умолчанию через таблицу маршрутизации
   (`ip -4 route show default`, с фолбэком на IPv6).
2. Если установлен NetworkManager — кладёт drop-in
   `/etc/NetworkManager/conf.d/no-dns.conf` (`dns=none`,
   `systemd-resolved=false`) и **перезапускает** NM.
3. Если есть `/etc/dhcp/dhclient.conf` — добавляет/обновляет строку
   `supersede domain-name-servers …`.
4. Сбрасывает per-link DNS на интерфейсе через `resolvectl revert`.
5. Перезаписывает `/etc/systemd/resolved.conf` блоком `[Resolve]` с
   `DNS=`, `FallbackDNS=`, опционально `DNSOverTLS=opportunistic` и
   `DNSSEC=allow-downgrade` (при `--dot`).
6. Перезапускает `systemd-resolved` и делает симлинк
   `/etc/resolv.conf → /run/systemd/resolve/stub-resolv.conf` (127.0.0.53).
7. Проверяет результат через `resolvectl status` и резолвинг тестового
   домена (`resolvectl query` → `dig` → `getent hosts` → `nslookup`).

### Предупреждения о netplan и cloud-init

На Ubuntu Server / cloud-образах сеть и DNS обычно описаны в
`/etc/netplan/*.yaml` и/или генерируются `cloud-init`. Скрипт:

- **Предупреждает**, если в `netplan` найдена секция `nameservers:` —
  её нужно поправить вручную, иначе DNS вернётся при следующем
  `netplan apply` / ребуте.
- **Предлагает** отключить управление сетью cloud-init, создав
  `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`
  (`network: {config: disabled}`). В режиме `--yes` отключается
  автоматически.

## Откат

```shell
sudo dns --rollback
```

Откат:

- удаляет `/etc/NetworkManager/conf.d/no-dns.conf`, перезапускает NM;
- вычищает `supersede domain-name-servers` из `/etc/dhcp/dhclient.conf`;
- удаляет `/etc/systemd/resolved.conf.d/nofallback.conf` (если остался
  от старой версии скрипта) и `99-disable-network-config.cfg` для
  cloud-init;
- сбрасывает `/etc/systemd/resolved.conf` к минимальному дефолту;
- делает `resolvectl revert <iface>` и перезапускает `systemd-resolved`.

> Примечание: исходный `/etc/systemd/resolved.conf` не сохраняется в
> бэкап. После `--rollback` ты получишь чистый `[Resolve]` без
> кастомных опций — это сознательный компромисс.

## Требования

- Ubuntu с `systemd-resolved` (22.04 / 24.04 точно ОК; 20.04 — должно
  работать).
- root (`sudo`).
- bash (скрипт использует `[[ … ]]`, `compgen`, parameter expansion).

## Опции

| Флаг                  | Назначение                                                              |
| --------------------- | ----------------------------------------------------------------------- |
| `-p, --provider NAME` | `yandex` / `cloudflare` / `google` / `quad9` (без меню).                |
| `-y, --yes`           | Неинтерактивный режим: все вопросы — «да».                              |
| `--dot`               | DNS-over-TLS (`opportunistic`) + DNSSEC (`allow-downgrade`).            |
| `--rollback`          | Откатить все изменения скрипта.                                         |
| `-h, --help`          | Показать справку.                                                       |
