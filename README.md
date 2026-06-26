# Xray VLESS + Reality в Docker

Скрипт для быстрого разворачивания личного VPN-сервера на базе **Xray** (протокол VLESS + Reality).
Трафик маскируется под обычный HTTPS — сложно заблокировать.

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/ziliboba-dev/vless-reality-docker-setup/main/xray.sh -o xray.sh && chmod +x xray.sh && sudo ./xray.sh
```

1. Скрипт выполнит всю настройку автоматически — введите **имя профиля** в конце.
2. Скопируйте полученную `vless://`-ссылку и вставьте в клиент (v2rayNG, Shadowrocket, Streisand и др.).
3. Готово — подключайтесь!

---

## Требования

| | |
|---|---|
| **Docker** | установлен и запущен (`docker version`) |
| **Root-доступ** | права `root` или `sudo` |
| **Linux-сервер** | Ubuntu, Debian, CentOS и любой другой дистрибутив |

---

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/ziliboba-dev/vless-reality-docker-setup/main/xray.sh -o xray.sh && \
chmod +x xray.sh && \
./xray.sh
```

Скрипт сам сгенерирует ключи, создаст конфиг и запустит контейнер. В конце предложит создать первый профиль.

---

## Управление профилями

```bash
./xray.sh create [имя]   # создать профиль (спросит имя если не передано)
./xray.sh list            # список всех профилей
./xray.sh show <имя>      # показать vless:// ссылку для подключения
./xray.sh revoke <имя>    # отозвать профиль
./xray.sh start           # запустить контейнер если он остановился
./xray.sh sync            # восстановить профили в конфиге (после сбоев)
```

### Пример

```bash
./xray.sh create phone
# → выводит vless://... ссылку — вставьте в клиент (v2rayNG, Streisand, Shadowrocket и т.д.)

./xray.sh list
# NAME      UUID                                   CREATED AT            ACTIVE
# phone     4530f0cd-3e72-41a8-af22-fec5df83f832   2026-06-26T17:16:43Z  yes

./xray.sh revoke phone   # отозвать, если телефон потерян
```

---

## Удаление

```bash
docker rm -f xray && rm -rf /etc/xray
```

Полностью удаляет контейнер и все конфигурации.

---

## Безопасность

- **VLESS + Reality** маскирует трафик под TLS-соединение с реальным сайтом (по умолчанию `www.apple.com`)
- Каждый профиль — отдельный UUID, его можно отозвать в любой момент без пересоздания сервера
- Конфиги хранятся на хосте в `/etc/xray/` и переживают перезапуск контейнера
