# KIT-Cascade v2 — техническая инструкция

[Главная страница и схема нод](../README.md) · [Подробная установка ENTRY](ENTRY.md) · [Архитектура](../docs/CASCADE_V2_ARCHITECTURE.md)

> **Экспериментальная ветка `multi-hop-v2`.** Установщик рассчитан на чистую Ubuntu 24.04. Не запускайте его поверх работающей установки 3X-UI KIT или Xray.

## Схема

```text
Клиент → ENTRY → [RELAY N → ... → RELAY 1] → EXIT → Интернет
              необязательные промежуточные ноды
```

Устанавливать следует **в обратном порядке**: EXIT, затем RELAY (если нужны), затем ENTRY. После установки EXIT/RELAY создаётся секретная VLESS/REALITY-ссылка. Её вводят в установщике **предыдущей** ноды, не публикуя в терминале историю ввода.

## Установка на каждой чистой ноде

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MasterriProtos/3X-UI_KIT-Cascade/multi-hop-v2/bootstrap.sh)
```

Bootstrap скачает репозиторий в `/opt/kit-cascade`, установит минимальные зависимости и запустит мастер выбора роли. Отдельная команда для конкретной роли после скачивания `bootstrap.sh`:

```bash
sudo bash bootstrap.sh --role exit
sudo bash bootstrap.sh --role relay
sudo bash bootstrap.sh --role entry
```

Если репозиторий уже скачан, используйте существующий checkout **только для диагностики** или для завершения прерванной установки штатной командой; не запускайте повторную полную установку поверх работающего сервера:

```bash
sudo python3 /opt/kit-cascade/cascade_v2/install.py entry-status
sudo python3 /opt/kit-cascade/cascade_v2/install.py status
```

Выполнить установку вручную из свежего checkout можно так:

```bash
git clone --depth 1 --branch multi-hop-v2 https://github.com/MasterriProtos/3X-UI_KIT-Cascade.git /opt/kit-cascade
sudo python3 /opt/kit-cascade/cascade_v2/install.py install --role exit
```

Вместо `exit` можно указать `relay` или `entry`.

## Что вводить в мастере

| Роль | Требуется | Результат |
|---|---|---|
| EXIT | Назначенный глобальный IPv6, порт, SNI/REALITY target | Ссылка для RELAY или ENTRY |
| RELAY | IPv6, порт, SNI, ссылка следующей ноды | Ссылка для предыдущего RELAY или ENTRY |
| ENTRY | Ссылка следующей ноды и параметры пользовательского KIT | Панель 3X-UI KIT, клиенты и подписки |

Ссылка содержит секреты — вводите её в защищённом SSH-сеансе. Мастер скрывает ввод. Вся конфигурация со служебными секретами остаётся на ноде; не коммитьте `/etc/kit-cascade` и резервные копии.

## Проверки

```bash
# EXIT или RELAY
sudo python3 /opt/kit-cascade/cascade_v2/install.py status
sudo python3 /opt/kit-cascade/cascade_v2/install.py show-link

# ENTRY
sudo python3 /opt/kit-cascade/cascade_v2/install.py entry-status
sudo python3 /opt/kit-cascade/cascade_v2/install.py entry-probe
sudo python3 /opt/kit-cascade/cascade_v2/install.py entry-mtproto-probe
sudo kit
```

Убедитесь, что входящий порт открыт в облачном файрволе у хостинга. Программа **не меняет SSH**, а для EXIT/RELAY не настраивает UFW, nftables, маршруты и системный DNS. Системные запросы ОС не имеют автоматического kill switch.

Для ENTRY установка — отдельный процесс с возможностью частичного завершения. Читайте [ENTRY.md](ENTRY.md) перед восстановлением и **не** применяйте обычную установку KIT отдельно.

## Восстановление

- EXIT/RELAY: `sudo python3 /opt/kit-cascade/cascade_v2/install.py restore` — останавливает управляемый Xray и восстанавливает исходную конфигурацию после подтверждения.
- ENTRY: сначала `entry-status`; для осознанного отката используйте `entry-restore` по [подробной инструкции](ENTRY.md).
- Не используйте `restore` как средство исправления неполадок мобильного MTProto: проблема может быть на сетевом маршруте, не в конфигурации ноды.

## Ограничения текущей версии

- Поддерживаемая система: **Ubuntu 24.04**, установка на чистую ноду.
- Межнодовой канал рассчитан на **IPv6 и VLESS/REALITY/TCP**.
- При недоступности следующей ноды RELAY не переключается на прямой выход.
- Пробное HTTPS-соединение проверяет внешний доступ цепочки; если тестовый сервис недоступен, установка может остановиться даже при работоспособной VLESS-связи.
- Нельзя делать вывод о доступности MTProto на каждой клиентской сети по успешной проверке с одного устройства.
- Готовность всей схемы к эксплуатации следует подтверждать сквозными проверками своих протоколов и операторов.

## Тестирование разработчиков

```bash
bash -n bootstrap.sh scripts/3x-ui.sh scripts/kit.sh
python3 scripts/audit_repo.py
python3 -m unittest discover -s cascade_v2/tests -v
```

В GitHub Actions дополнительно тестируются конфигурации Xray и транспорт между EXIT/RELAY.
