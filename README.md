# GhostBox

**Alpha 0.1.0 · Linux x86_64 · Xray-core + sing-box**

## Русский

GhostBox — VPN-клиент на Flutter с ядрами Xray и sing-box. Linux поддерживает оба ядра. На Android подключение выполняется через системный `VpnService` и sing-box libbox; Windows поддерживает системный прокси и TUN с запросом прав администратора. macOS и iOS пока находятся на этапе подготовки ядер и runner-проектов.

### Возможности

- Импорт VLESS, VMess, Trojan, Shadowsocks, JSON-профилей и URL-подписок; несколько подписок и автообновление.
- Режимы TUN, локальный прокси, системный прокси и Mixed.
- Xray по умолчанию; Xray XHTTP/REALITY и Linux TUN через sing-box-маршрутизатор.
- Настройки DNS, маршрутов, DNS-блоклистов, локального порта, журналов и мягкого лимита памяти ядра.
- Split tunneling по доменам и IP/CIDR; поддерживается импорт JSON-списков Amnezia.
- Проверка серверов, журнал в файл, история последних подключений и просмотр сгенерированных конфигов.
- Необязательный индикатор RAM ядер на главном экране.
- Данные подписки — трафик, срок действия, устройства, сайт и поддержка — отображаются, только если их прислал провайдер.
- Скрипты сборки Xray/sing-box для Windows и macOS, sing-box libbox для Android и Apple.

Windows-сборка включает установщик и системный прокси текущего пользователя. При выборе TUN приложение запросит права администратора Windows. Для Android есть отдельный workflow, который собирает APK вместе с libbox. Сборка и статус платформ описаны в [deploy/PLATFORMS.md](deploy/PLATFORMS.md).

Поддержка протоколов и транспортов зависит от ядра и его параметров сборки. Для XHTTP и REALITY выбирай Xray: поставляемая сборка sing-box может не содержать дополнительных тегов XHTTP/uTLS.

### Установка

Для локальной сборки выбери платформу одной командой:

```bash
./tool/build.sh
```

Или укажи `linux`, `android`, `windows`, `macos` либо `ios`. Скрипт скачает
Go/Flutter зависимости и ядра, соберёт доступный для текущей ОС пакет; Android
SDK можно установить через `tool/setup_android.sh`. Linux создаёт AppImage и
предлагает установить его и один раз выдать ядрам право TUN. Windows и Apple
приложения собираются на Windows и macOS соответственно; для Windows на Linux
используй GitHub Actions.

Скачай `GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage` из GitHub Releases и запусти:

```bash
chmod +x GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

Чтобы установить приложение в меню рабочего стола без прав root, из клона репозитория выполни:

```bash
./tool/install_appimage.sh ./dist/GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

Добавь ссылку-подписку или сервер, выбери профиль и нажми кнопку подключения. TUN включён по умолчанию. Если AppImage не запускается из-за отсутствия FUSE, попробуй `APPIMAGE_EXTRACT_AND_RUN=1 ./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage`.

### TUN без запуска VPN от root

Linux требует однократно выдать ядру `CAP_NET_ADMIN`, чтобы оно могло создать TUN-интерфейс и настроить маршруты. Сначала запусти AppImage один раз: он скопирует ядро в каталог пользователя. Затем выполни:

```bash
sudo setcap cap_net_admin+ep "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
getcap "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
```

На Void Linux, если `setcap` не найден: `sudo xbps-install -S libcap-progs`. Если переменная `XDG_DATA_HOME` задана, путь будет `$XDG_DATA_HOME/ghostbox-appimage/vendor/bin/sing-box`. При ошибке прав приложение покажет команду для текущего пути и кнопку копирования. `sudo` нужен только для однократной выдачи capability; сам GhostBox и VPN затем работают от твоего пользователя. После обновления AppImage эту команду может потребоваться повторить. Устройство `/dev/net/tun` должно существовать.

### Windows и Android

В GitHub Actions запусти workflow **Build GhostBox for Windows** или **Build GhostBox for Android**. Windows workflow выдаёт `GhostBox-Setup-x64.exe`; Android workflow — `GhostBox-Android-universal.apk`. APK подписан тестовым ключом сборки и подходит для установки вручную. При подключении Android запросит системное разрешение VPN.

### Сборка из исходников

Для локальной сборки используй скрипт. Он скачает зависимости, соберёт ядра и приложение, а на Linux создаст AppImage:

```bash
./build.sh
```

Чтобы выбрать Linux без меню: `./build.sh linux`. После сборки установить AppImage в меню можно командой `./tool/install_appimage.sh ./dist/GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage`. Другие платформы выбираются в меню скрипта; требования платформ описаны в [deploy/PLATFORMS.md](deploy/PLATFORMS.md).

### Приватность и диагностика

Настройки и профили хранятся локально. User-Agent содержит только имя и версию клиента; ID установки, ОС, версию ОС, модель системы и архитектуру GhostBox передаёт отдельными заголовками запросов подписки и XHTTP. На Linux модель берётся из системного DMI, если он доступен; иначе отправляется `Linux PC`. Клиент не отправляет MAC-адрес, серийный номер оборудования или имя компьютера. Панель провайдера должна поддерживать эти заголовки; у VLESS поверх обычного TLS/TCP нет универсального поля устройства.

Файл `.env` предназначен только для локальной разработки, исключён из Git и не встраивается в приложение. Не публикуй подписки, токены, приватные ключи и JSON с учётными данными. Перед передачей журналов удали из них секреты.

### Статус альфа-релиза

Текущая цель — Linux x86_64. Альфа требует проверки на твоём сервере и сети; держи возможность вернуться к предыдущему VPN и не запускай два TUN-клиента одновременно. Подробности и шаги установки — в [RELEASE-ALPHA.md](RELEASE-ALPHA.md).

## English

GhostBox is a Flutter VPN client powered by Xray and sing-box. Linux supports both cores. Android connects through the system `VpnService` and sing-box libbox; Windows supports the current user's system proxy and TUN with a Windows administrator prompt. macOS and iOS currently have core and runner build preparation only.

### Features

- Import VLESS, VMess, Trojan, Shadowsocks, JSON profiles and subscription URLs; manage multiple subscriptions and refresh them automatically.
- TUN, local proxy, system proxy and Mixed connection modes.
- Xray is the default core. Xray supports XHTTP/REALITY; Linux TUN can route through a sing-box bridge.
- DNS, routing, DNS blocklists, local port, logging and a soft core memory budget.
- Domain and IP/CIDR split tunneling, including Amnezia JSON route lists.
- Server checks, file-based logs, recent connection history and generated-config viewer.
- Optional live core RAM usage on the main screen.
- Provider metadata such as traffic, expiry, device limit, website and support is shown only when supplied by the provider.
- Build scripts for Windows/macOS Xray and sing-box, Android libbox, and the Apple Libbox XCFramework.

The Windows build includes an installer and the current user's system proxy. Selecting TUN prompts for administrator rights. Android has a separate workflow that builds the APK with libbox. See [deploy/PLATFORMS.md](deploy/PLATFORMS.md) for build commands and platform status.

Protocol and transport support depends on the selected core and its build options. Choose Xray for XHTTP and REALITY; the bundled sing-box build may not include optional XHTTP/uTLS tags.

### Install

Build locally with an interactive platform picker:

```bash
./tool/build.sh
```

You can also pass `linux`, `android`, `windows`, `macos`, or `ios`. The script
fetches Go/Flutter dependencies and core binaries, then builds what the current
host can produce. Android SDK setup is available through
`tool/setup_android.sh`. Linux creates an AppImage and offers to install it and
grant the core binaries TUN capability once. Windows and Apple app builds need
their native operating systems; use GitHub Actions for Windows from Linux.

Download `GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage` from GitHub Releases and run:

```bash
chmod +x GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

To add GhostBox to the desktop app menu without root access, run this from a repository checkout:

```bash
./tool/install_appimage.sh ./dist/GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage
```

Add a subscription URL or server, select a profile and press Connect. TUN is enabled by default. If AppImage cannot start because FUSE is unavailable, try `APPIMAGE_EXTRACT_AND_RUN=1 ./GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage`.

### TUN without running the VPN as root

Linux requires a one-time `CAP_NET_ADMIN` capability so the core can create a TUN interface and configure routes. Launch the AppImage once to copy its core into your user data directory, then run:

```bash
sudo setcap cap_net_admin+ep "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
getcap "$HOME/.local/share/ghostbox-appimage/vendor/bin/sing-box"
```

On Void Linux, install `libcap-progs` if `setcap` is missing: `sudo xbps-install -S libcap-progs`. If `XDG_DATA_HOME` is set, use `$XDG_DATA_HOME/ghostbox-appimage/vendor/bin/sing-box`. On a permissions error, the app shows the exact command for the current path with a copy button. `sudo` is needed only once to grant the capability; GhostBox and the VPN then run as your normal user. Repeat the command after an AppImage update if its core binary changes. `/dev/net/tun` must exist.

### Windows and Android

Run **Build GhostBox for Windows** or **Build GhostBox for Android** from GitHub Actions. The Windows workflow publishes `GhostBox-Setup-x64.exe`; the Android workflow publishes `GhostBox-Android-universal.apk`. The APK uses the build's test signing key for sideloading and requests Android's VPN permission when connecting.

### Build from source

Use the build script. It fetches dependencies, builds the cores and app, and creates an AppImage on Linux:

```bash
./build.sh
```

For a direct Linux build without the target picker: `./build.sh linux`. To install the resulting AppImage into the desktop menu, run `./tool/install_appimage.sh ./dist/GhostBox-0.1.0-alpha.1-linux-x86_64.AppImage`. Choose other targets in the script menu; platform requirements are listed in [deploy/PLATFORMS.md](deploy/PLATFORMS.md).

### Privacy and diagnostics

Settings and profiles are stored locally. The User-Agent contains only the client name and version; GhostBox sends the installation ID, OS, OS version, system model and architecture in separate subscription and XHTTP request headers. On Linux, the model is read from system DMI when available; otherwise `Linux PC` is sent. The client does not send a MAC address, hardware serial number or computer hostname. The provider panel must support these headers; VLESS over ordinary TLS/TCP has no universal device-information field.

`.env` is for local development, is ignored by Git and is not bundled into the app. Do not publish subscription URLs, tokens, private keys or profile JSON containing credentials. Redact secrets before sharing logs.

### Alpha status

The current target is Linux x86_64. Validate this alpha with your server and network, keep your previous VPN available, and do not run two TUN clients at once. See [RELEASE-ALPHA.md](RELEASE-ALPHA.md) for release notes and installation steps.

## License

This repository has not declared a project license. Third-party components retain their own licenses: [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box).
