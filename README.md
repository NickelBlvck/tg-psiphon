# tg-psiphon

**`psiphon-route`** — один Bash-скрипт для Linux-сервера (VPS), который поднимает **TUN-интерфейс поверх Psiphon** и направляет через него **только выбранный трафик**: по умолчанию — весь Telegram и `api.telegram.org`. Остальной трафик идёт напрямую, дефолтный маршрут не трогается.

Рассчитан на стек [RemnaSuper](https://github.com/obkaiter/RemnaSuper) → [vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon): Psiphon работает в Docker и отдаёт локальный SOCKS5 (порт `1080`, только TCP). Но подойдёт и любой другой локальный SOCKS5.

---

## Как это работает

```
приложения хоста ──(ip route)──▶ psiphon0 (TUN) ──▶ tun2socks (Docker)
      ──▶ SOCKS5 vps-psiphon ──▶ Psiphon ──▶ интернет
```

- Скрипт поднимает контейнер [tun2socks](https://github.com/xjasonlyu/tun2socks) (`--net host`), который создаёт интерфейс `psiphon0` и заворачивает его пакеты в SOCKS5 Psiphon.
- В таблицу маршрутов добавляются **только нужные префиксы**: официальный список Telegram CIDR + адреса доменов из вашего списка.
- Домены резолвятся автоматически; systemd-таймер каждые 5 минут обновляет их `/32`-маршруты и чинит туннель, если что-то отвалилось.
- Есть защита от петли: маршрут, накрывающий адрес SOCKS5, не добавляется.

## Быстрый старт (чистый VPS)

Ubuntu/Debian, от root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NickelBlvck/tg-psiphon/main/psiphon-route.sh) install
```

`install` сам:

1. поставит недостающие утилиты и **Docker** (официальный `get.docker.com`);
2. проверит `/dev/net/tun` (`modprobe tun`);
3. создаст конфиг `/etc/psiphon-route/psiphon-route.conf` и список маршрутов `/etc/psiphon-route/routes.list`;
4. поставит systemd-юниты (`psiphon-route.service` + таймер `psiphon-route-refresh.timer`);
5. **если Psiphon не найден — предложит установить vps-psiphon** (установщик Chara-Freedom, флаг `--no-http`);
6. запустит туннель и покажет `status`.

Всё занимает пару минут и переживает перезагрузку: docker поднимает контейнеры сам (`--restart unless-stopped`), systemd заново применяет маршруты, таймер поддерживает DNS.

### Если Psiphon уже стоит (например, через RemnaSuper)

Скрипт найдёт его SOCKS5 автоматически (`docker0`/`127.0.0.1`, порты 1080–1085) и просто запустится:

```bash
bash psiphon-route.sh install
# или без копирования юнитов:
psiphon-route start
```

## Куда указывать трафик

`/etc/psiphon-route/routes.list` — по одной строке:

```
# CIDR (v4 и v6)
91.108.4.0/22
2001:67c:4e8::/48

# отдельный IP
149.154.167.220

# домен — резолвится сам, обновляется таймером
api.telegram.org
```

По умолчанию в списке уже есть:

- официальный список Telegram CIDR (блок между маркерами `# >>> telegram … # <<< telegram`, обновляется командой `psiphon-route update-cidrs`);
- `api.telegram.org` (можно раскомментировать `web.telegram.org`).

После правок — `psiphon-route refresh`, перезапуск не нужен.

> ⚠️ **Не добавляйте** `t.me` и прочее за Cloudflare — тогда через Psiphon пойдёт значительная часть интернета. Wildcard (`*.example.com`) не поддерживается — добавляйте конкретные поддомены.

## Команды

| Команда | Что делает |
|---|---|
| `install` | установка на чистую машину: зависимости, Docker, конфиг, systemd, запуск |
| `start` / `stop` / `restart` | поднять / снять туннель и маршруты |
| `refresh` | пере-резолвить домены, восстановить маршруты |
| `status` | контейнер, интерфейс, выход Psiphon, `HTTP api.telegram.org` с хоста |
| `update-cidrs` | обновить Telegram CIDR из `core.telegram.org/resources/cidr.txt` |
| `install-psiphon` | установить vps-psiphon (`--no-http`; регион — `PSIPHON_REGION` в конфиге) |
| `logs [N]` | логи tun2socks (по умолчанию 100 строк) |
| `uninstall` | удалить psiphon-route (vps-psiphon не трогает) |

## Конфиг `/etc/psiphon-route/psiphon-route.conf`

```bash
PSIPHON_SOCKS=""     # хост:порт; пусто = авто-поиск 1080-1085 на docker0/127.0.0.1
MTU=""               # например 1400, если понадобится
ENABLE_IPV6=0        # 1 = маршрутизировать и IPv6-записи из списка
PSIPHON_REGION=""    # регион выхода для install-psiphon: "DE" или пул "NL,DE,SE"
```

Для сервера в РФ рекомендую сразу зафиксировать пул выхода рядом: `PSIPHON_REGION="NL,DE,SE"` — низкая задержка и стабильные экзиты вместо авто-подбора.

Второй инстанс Psiphon из vps-psiphon (порт 1081+): `PSIPHON_SOCKS="172.17.0.1:1081"`.

## Файлы

| Путь | Что там |
|---|---|
| `/usr/local/bin/psiphon-route` | сам скрипт |
| `/etc/psiphon-route/routes.list` | **список трафика** (главный файл для правок) |
| `/etc/psiphon-route/psiphon-route.conf` | конфиг |
| `/var/lib/psiphon-route/domain-ips` | state: какие IP каким доменам соответствуют |

## Ограничения

- **UDP через туннель не ходит** — SOCKS5 vps-psiphon работает только по TCP. Текст, медиа и боты Telegram работают; голосовые/видеозвонки (UDP) — нет. Это ограничение vps-psiphon, а не скрипта.
- Маршруты живут в основной таблице — они затрагивают и форварднутый трафик, если сервер им занимается (RemnaNode обычно работает в userspace, так что не страшно).
- Разрешение доменов идёт через системный DNS напрямую. Сам клиент Telegram от этого не зависит (ходит по IP из CIDR-блока). Если ваш DNS подменяет записи — добавляйте домены по IP/CIDR вручную.
- Смена региона/ротация в vps-psiphon рвёт туннель на ~45 секунд — маршруты трогать не нужно, они на уровне IP.

## Диагностика

```bash
psiphon-route status            # сводка + HTTP-код api.telegram.org
psiphon-route logs 200          # логи tun2socks
ip route show dev psiphon0      # что реально завёрнуто в туннель
journalctl -u psiphon-route -e  # журнал сервиса
systemctl list-timers | grep psiphon
```

Проверка туннеля в обход маршрутов:

```bash
curl --socks5-hostname 127.0.0.1:1080 https://api.telegram.org
```

## Благодарности

- [RemnaSuper](https://github.com/obkaiter/RemnaSuper) — панель управления RemnaNode, где Psiphon ставится из меню
- [vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) — Psiphon как Docker-сервис с SOCKS5 и watchdog
- [tun2socks](https://github.com/xjasonlyu/tun2socks) — TUN → SOCKS5
- [Psiphon](https://psiphon.ca/) — сама сеть обхода блокировок
