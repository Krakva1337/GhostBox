# GhostBox

**Alpha 0.1.0 · Linux x86_64 · Xray-core + sing-box**

## Русский

GhostBox — настольный VPN-клиент для Linux. Он импортирует серверы и подписки, запускает Xray или sing-box и показывает диагностику соединения. Текущая альфа ориентирована на Linux; Windows будет следующим этапом. Android-папка пока содержит только заготовку интерфейса.

### Возможности

- Импорт VLESS, VMess, Trojan, Shadowsocks, JSON-профилей и URL-подписок; несколько подписок и автообновление.
- Режимы TUN, локальный прокси, системный прокси и Mixed.
- Xray по умолчанию; Xray XHTTP/REALITY и Linux TUN через sing-box-маршрутизатор.
- Настройки DNS, маршрутов, DNS-блоклистов, локального порта, журналов и мягкого лимита памяти ядра.
- Проверка серверов, журнал в файл, история последних подключений и просмотр сгенерированных конфигов.
- Необязательный индикатор RAM ядер на главном экране.
- Данные подписки — трафик, срок действия, устройства, сайт и поддержка — отображаются, только если их прислал провайдер.

Поддержка протоколов и транспортов зависит от ядра и его параметров сборки. Для XHTTP и REALITY выбирай Xray: поставляемая сборка sing-box может не содержать дополнительных тегов XHTTP/uTLS.

### Установка

Скачай `GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage` из GitHub Releases и запусти:

```bash
chmod +x GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

Чтобы установить приложение в меню рабочего стола без прав root, из клона репозитория выполни:

```bash
./tool/install_appimage.sh ./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

Добавь ссылку-подписку или сервер, выбери профиль и нажми кнопку подключения. TUN включён по умолчанию. Если AppImage не запускается из-за отсутствия FUSE, попробуй `APPIMAGE_EXTRACT_AND_RUN=1 ./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage`.

### TUN без запуска VPN от root

Linux требует однократно выдать ядру `CAP_NET_ADMIN`, чтобы оно могло создать TUN-интерфейс и настроить маршруты. Сначала запусти AppImage один раз: он скопирует ядро в каталог пользователя. Затем выполни:

```bash
sudo setcap cap_net_admin+ep "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
getcap "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
```

На Void Linux, если `setcap` не найден: `sudo xbps-install -S libcap-progs`. Если переменная `XDG_DATA_HOME` задана, путь будет `$XDG_DATA_HOME/ghostbox-appimage/vendor/bin/sing-box`. При ошибке прав приложение покажет команду для текущего пути и кнопку копирования. `sudo` нужен только для однократной выдачи capability; сам GhostBox и VPN затем работают от твоего пользователя. После обновления AppImage эту команду может потребоваться повторить. Устройство `/dev/net/tun` должно существовать.

### Сборка из исходников

Нужны Flutter 3.19+ и системные инструменты сборки Linux. В этой рабочей копии используется Flutter 3.47.7.

```bash
flutter pub get
./tool/fetch_cores.sh
flutter build linux --release
```

Инструкции подготовки Android и Windows находятся в [deploy/PLATFORMS.md](deploy/PLATFORMS.md); эти платформы пока не входят в альфа-релиз.

### Приватность и диагностика

Настройки и профили хранятся локально. GhostBox передаёт случайный постоянный ID установки, версию клиента и минимальные данные ОС/архитектуры в заголовках запросов подписки и XHTTP. Клиент не отправляет MAC-адрес, серийный номер оборудования или имя компьютера. Чтобы панель провайдера показала ОС вместо `Unknown`, она должна распознавать заголовки GhostBox; универсального поля устройства в VLESS нет.

Файл `.env` предназначен только для локальной разработки, исключён из Git и не встраивается в приложение. Не публикуй подписки, токены, приватные ключи и JSON с учётными данными. Перед передачей журналов удали из них секреты.

### Статус альфа-релиза

Текущая цель — Linux x86_64. Альфа требует проверки на твоём сервере и сети; держи возможность вернуться к предыдущему VPN и не запускай два TUN-клиента одновременно. Подробности и шаги установки — в [RELEASE-ALPHA.md](RELEASE-ALPHA.md).

## English

GhostBox is a Linux desktop VPN client for importing servers and subscriptions, running Xray or sing-box, and diagnosing connections. This alpha targets Linux; Windows is planned next. The Android directory currently contains a UI scaffold only.

### Features

- Import VLESS, VMess, Trojan, Shadowsocks, JSON profiles and subscription URLs; manage multiple subscriptions and refresh them automatically.
- TUN, local proxy, system proxy and Mixed connection modes.
- Xray is the default core. Xray supports XHTTP/REALITY; Linux TUN can route through a sing-box bridge.
- DNS, routing, DNS blocklists, local port, logging and a soft core memory budget.
- Server checks, file-based logs, recent connection history and generated-config viewer.
- Optional live core RAM usage on the main screen.
- Provider metadata such as traffic, expiry, device limit, website and support is shown only when supplied by the provider.

Protocol and transport support depends on the selected core and its build options. Choose Xray for XHTTP and REALITY; the bundled sing-box build may not include optional XHTTP/uTLS tags.

### Install

Download `GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage` from GitHub Releases and run:

```bash
chmod +x GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

To add GhostBox to the desktop app menu without root access, run this from a repository checkout:

```bash
./tool/install_appimage.sh ./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

Add a subscription URL or server, select a profile and press Connect. TUN is enabled by default. If AppImage cannot start because FUSE is unavailable, try `APPIMAGE_EXTRACT_AND_RUN=1 ./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage`.

### TUN without running the VPN as root

Linux requires a one-time `CAP_NET_ADMIN` capability so the core can create a TUN interface and configure routes. Launch the AppImage once to copy its core into your user data directory, then run:

```bash
sudo setcap cap_net_admin+ep "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
getcap "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
```

On Void Linux, install `libcap-progs` if `setcap` is missing: `sudo xbps-install -S libcap-progs`. If `XDG_DATA_HOME` is set, use `$XDG_DATA_HOME/ghostbox-appimage/vendor/bin/sing-box`. On a permissions error, the app shows the exact command for the current path with a copy button. `sudo` is needed only once to grant the capability; GhostBox and the VPN then run as your normal user. Repeat the command after an AppImage update if its core binary changes. `/dev/net/tun` must exist.

### Build from source

Requirements: Flutter 3.19+ and the Linux desktop build toolchain. This workspace uses Flutter 3.47.7.

```bash
flutter pub get
./tool/fetch_cores.sh
flutter build linux --release
```

Android and Windows preparation notes are in [deploy/PLATFORMS.md](deploy/PLATFORMS.md); these platforms are not part of the alpha release yet.

### Privacy and diagnostics

Settings and profiles are stored locally. GhostBox sends a stable random installation ID, client version and basic OS/architecture details in subscription and XHTTP request headers. It does not send a MAC address, hardware serial number or computer hostname. A provider panel must recognize GhostBox headers to display the OS instead of `Unknown`; VLESS has no universal device-information field.

`.env` is for local development, is ignored by Git and is not bundled into the app. Do not publish subscription URLs, tokens, private keys or profile JSON containing credentials. Redact secrets before sharing logs.

### Alpha status

The current target is Linux x86_64. Validate this alpha with your server and network, keep your previous VPN available, and do not run two TUN clients at once. See [RELEASE-ALPHA.md](RELEASE-ALPHA.md) for release notes and installation steps.

## License

This repository has not declared a project license. Third-party components retain their own licenses: [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box).
