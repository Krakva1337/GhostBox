<p align="center">
  <img src="assets/icons/aurora.svg" width="112" alt="Логотип GhostBox">
</p>

<h1 align="center">GhostBox</h1>

<p align="center">
  <a href="https://github.com/Krakva1337/GhostBox/releases">
    <img src="https://img.shields.io/github/v/release/Krakva1337/GhostBox?include_prereleases&label=Скачать%20релиз&style=for-the-badge" alt="Скачать GhostBox из GitHub Releases">
  </a>
</p>

<p align="center"><a href="#русский">Русский</a> · <a href="#english">English</a></p>

## Русский

GhostBox — клиент для подключения к VPN-серверам и управления их маршрутами. **Alpha**.

## Скачать и установить

Все опубликованные файлы находятся на странице **[GitHub Releases](https://github.com/Krakva1337/GhostBox/releases)**. Открой последний релиз и выбери файл для своей платформы.

| Платформа | Файл | Установка |
| --- | --- | --- |
| Windows x64 | `GhostBox-…-Windows-x64-Setup.exe` | Скачай и запусти установщик. Для TUN подтверди запрос администратора Windows. |
| Windows x64, без установки | `GhostBox-…-Windows-x64.zip` | Распакуй архив и запусти `GhostBox.exe`. Для TUN понадобится подтверждение UAC. |
| Linux x86_64 | `GhostBox-…-linux-x86_64.AppImage` | Сделай файл исполняемым и запусти. |
| Linux ARM64 | `GhostBox-…-linux-aarch64.AppImage` | Используй на ARM64 Linux; архитектуры x86_64 и ARM64 не взаимозаменяемы. |
| Android | `GhostBox-Android-universal.apk`, если он приложен к релизу | Скачай APK, открой его из «Загрузок» и подтверди установку. Android попросит разрешение на VPN. |

Для AppImage, если система не запускает загруженные файлы, открой терминал в каталоге загрузок и выполни:

```bash
chmod +x ./GhostBox-*-linux-*.AppImage
```

Затем запусти скачанный AppImage двойным щелчком в файловом менеджере. Если загружено несколько версий, выбери нужный файл.

На некоторых системах для режима TUN потребуется однократно разрешить ядру настройку сетевого интерфейса. GhostBox подскажет нужное действие, если обнаружит проблему с правами. Если TUN не нужен, можно выбрать доступный на платформе режим прокси.

**Android APK публикуется отдельно от автоматических сборок Windows/Linux.** Если в последнем релизе нет файла APK, значит Android-сборка для этой версии пока не выложена. Для обновления APK из приложения в релизе также должен быть файл проверки с именем APK плюс `.sha256`.

## Первое подключение

1. Нажми **Добавить** и импортируй ссылку на отдельный сервер, URL подписки или файл конфигурации.
2. Выбери сервер из списка.
3. Выбери доступный для устройства режим подключения и нажми кнопку питания.
4. При первом запуске подтверди системное разрешение VPN. На Windows для TUN также подтверди запрос администратора.

Подписка может содержать несколько серверов. Обновляй её кнопкой у подписки или включи автообновление в настройках. Если поставщик подписки отправляет данные об остатке трафика или сроке действия, GhostBox покажет их в карточке подписки.

## Ядра и режимы подключения

Ядро обрабатывает подключение к выбранному серверу. По умолчанию используется Xray; sing-box доступен на платформах и для профилей, где он поддерживается. Некоторые режимы и ядра зависят от устройства и типа профиля.

- **Прокси** — локальный SOCKS/HTTP-прокси для приложений, в которых его можно указать вручную.
- **Системный прокси** — направляет через прокси приложения, которые используют настройки прокси операционной системы.
- **TUN / VPN** — создаёт системный VPN-интерфейс и направляет через него трафик приложений. На Android используется системный VPN.
- **Mixed** — сочетает системный маршрут TUN с локальным прокси.

На Android используется системный VPN-режим; другие варианты могут быть недоступны. Режим TUN на Windows требует подтверждения администратора. Доступность режимов также зависит от выбранного ядра и профиля.

## Раздельная маршрутизация, DNS и проверки

В разделе **Маршрут и DNS** можно выбрать, как использовать списки правил:

- **Через сервер** — подходящий трафик отправляется через VPN-сервер.
- **Напрямую** — подходящий трафик идёт через обычное подключение к интернету.
- **Домены и IP/CIDR** — правила задаются доменами или адресами. Например, `example.org` включает домен и поддомены, `*.example.org` — только поддомены, а `full:example.org` — только точное имя.
- **Приложения** — выбор приложений доступен там, где его предоставляет платформа.

Для DNS по умолчанию выбраны **Cloudflare + Google**. DNS можно изменить в настройках. При проверке подключения выбери TCP-пинг для быстрой проверки доступности сервера; Proxy GET проверяет запрос через активный прокси/VPN.

Правила по доменам зависят от того, видит ли ядро имя сайта. Зашифрованный DNS и ECH иногда скрывают домен; в таком случае используй правило по IP/CIDR. У сайтов с CDN адреса могут меняться, поэтому IP-правило может требовать обновления.

## Обновления

Новые версии появляются на странице [GitHub Releases](https://github.com/Krakva1337/GhostBox/releases). В приложении можно проверять обновления и настроить, когда показывать предложение. На Android APK скачивается в «Загрузки»; открой файл и подтверди установку вручную.

## Поддержка и сообщения об ошибках

- Telegram-канал проекта: [t.me/GhostBoxVPN](https://t.me/GhostBoxVPN).
- Сообщить об ошибке или предложить улучшение: [GitHub Issues](https://github.com/Krakva1337/GhostBox/issues).

В сообщении об ошибке укажи платформу, версию GhostBox, выбранный режим и шаги, после которых возникла проблема. Перед отправкой журналов проверь, что в них нет ссылок подписок, UUID, паролей или других личных данных.

## English

GhostBox is a client for connecting to VPN servers and managing their traffic routes. **Alpha**.

## Download and install

All published files are on the **[GitHub Releases](https://github.com/Krakva1337/GhostBox/releases)** page. Open the latest release and choose the file for your platform.

| Platform | File | Installation |
| --- | --- | --- |
| Windows x64 | `GhostBox-…-Windows-x64-Setup.exe` | Download and run the installer. Approve the Windows administrator prompt for TUN. |
| Windows x64, portable | `GhostBox-…-Windows-x64.zip` | Extract the archive and run `GhostBox.exe`. Approve the UAC prompt for TUN. |
| Linux x86_64 | `GhostBox-…-linux-x86_64.AppImage` | Make the file executable and run it. |
| Linux ARM64 | `GhostBox-…-linux-aarch64.AppImage` | Use on ARM64 Linux; x86_64 and ARM64 builds are not interchangeable. |
| Android | `GhostBox-Android-universal.apk`, when attached to the release | Download the APK, open it from Downloads, and confirm installation. Android will ask for VPN permission. |

If your system will not launch the AppImage, open a terminal in the download folder and run:

```bash
chmod +x ./GhostBox-*-linux-*.AppImage
```

Then launch the downloaded AppImage by double-clicking it in your file manager. If you downloaded multiple versions, choose the one you want to run.

On some systems, TUN mode requires a one-time permission for the core to configure a network interface. GhostBox will explain what to do if it detects a permissions problem. If you do not need TUN, you can select an available proxy mode.

**The Android APK is published separately from the automatic Windows/Linux builds.** If the latest release has no APK, the Android build for that version has not been uploaded. In-app APK updates also require a checksum file named by appending `.sha256` to the APK filename.

## First connection

1. Select **Add** and import a link to a server, a subscription URL, or a configuration file.
2. Choose a server from the list.
3. Select a connection mode available on your device and tap the power button.
4. On the first connection, approve the system VPN permission. On Windows, also approve the administrator prompt for TUN.

A subscription can contain several servers. Refresh it with the button on its card or enable automatic refresh in settings. GhostBox shows usage or expiry details only when the subscription provider supplies them.

## Cores and connection modes

A core handles the connection to the selected server. Xray is selected by default; sing-box is available on platforms and for profiles that support it. Some modes and cores depend on the device and profile type.

- **Proxy** — a local SOCKS/HTTP proxy for apps where you can enter proxy settings manually.
- **System proxy** — routes apps that use the operating system's proxy settings through the proxy.
- **TUN / VPN** — creates a system VPN interface and routes app traffic through it. Android uses the system VPN.
- **Mixed** — combines the system TUN route with a local proxy.

Android uses system VPN mode; other modes may not be available there. Windows requires administrator approval for TUN. Available modes also depend on the selected core and profile.

## Split routing, DNS, and checks

In **Routing and DNS**, you can choose how to use routing rules:

- **Through the server** — matching traffic goes through the VPN server.
- **Direct** — matching traffic uses your regular internet connection.
- **Domains and IP/CIDR** — rules can use domain names or addresses. For example, `example.org` matches the domain and its subdomains, `*.example.org` matches subdomains only, and `full:example.org` matches the exact hostname.
- **Apps** — app selection is available where the platform provides it.

The default DNS resolver is **Cloudflare + Google**. You can change it in settings. Choose TCP ping for a quick server availability check; Proxy GET checks a request through the active proxy/VPN.

Domain rules depend on whether the core can see the site's hostname. Encrypted DNS and ECH can hide it; use an IP/CIDR rule in that case. CDN addresses can change, so an IP rule for a CDN-backed site may need updating.

## Updates

New versions are published on [GitHub Releases](https://github.com/Krakva1337/GhostBox/releases). You can check for updates in the app and configure when update offers appear. On Android, the APK is saved to Downloads; open it and confirm installation manually.

## Support and bug reports

- Project Telegram channel: [t.me/GhostBoxVPN](https://t.me/GhostBoxVPN).
- Report a bug or suggest an improvement: [GitHub Issues](https://github.com/Krakva1337/GhostBox/issues).

When reporting a problem, include your platform, GhostBox version, selected mode, and the steps that caused it. Before sharing logs, check that they do not contain subscription links, UUIDs, passwords, or other private data.
