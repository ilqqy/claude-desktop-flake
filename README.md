# claude-desktop-flake

Nix flake для **Claude Desktop** (Chat, Code, Cowork) на NixOS `x86_64-linux` и `aarch64-linux`.

> **Неофициально.** Это репак официального Linux-пакета Anthropic (beta, `.deb` для
> Ubuntu/Debian) силами сообщества. Anthropic NixOS не поддерживает. С багами этого
> флейка не надо идти в поддержку Anthropic. Приложение проприетарное
> (`meta.license = unfree`), флейк его не распространяет: `.deb` скачивается с
> `downloads.claude.ai` при сборке.

## Откуда берётся приложение

С лета 2026 года (источники называют 30 июня или 9 июля) у Anthropic есть официальная Linux-сборка (beta), см.
[code.claude.com/docs/en/desktop-linux](https://code.claude.com/docs/en/desktop-linux).
Её публикуют в apt-репозитории `https://downloads.claude.ai/claude-desktop/apt/stable`
для `amd64` и `arm64`, без авторизации. Поэтому Windows-инсталлер и заглушки для
нативных модулей (как у старых k3d3 / aaddrick ≤ 2.x) больше не нужны:
`claude-native-binding.node` и `node-pty` в `.deb` уже собраны под Linux. `app.asar`
попадает в пакет без изменений.

## Почему buildFHSEnv, а не electron из nixpkgs

1. Electron из nixpkgs не подходит: приложение читает локали, хелперы Cowork и образ ВМ
   из `process.resourcesPath`, а этот путь Electron вычисляет по `/proc/self/exe`.
   Поэтому берём родной Electron 44 из `.deb` и чиним его через `autoPatchelfHook`.
2. Вкладка Code сама скачивает glibc-бинарь Claude Code (`/lib64/ld-linux-*.so.2`) в
   `~/.config/Claude/claude-code/`. На NixOS без `nix-ld` он не запустится. Кроме того,
   приложение вызывает `/bin/bash`, `/usr/bin/pgrep`, `/usr/bin/secret-tool` и т. п.
   по абсолютным путям. В FHS-окружении работает и то и другое, без патчей asar.

## Установка

```sh
nix run github:<you>/claude-desktop-flake   # unfree для этого пакета уже разрешён внутри флейка
nix build && ./result/bin/claude-desktop    # из клона
```

NixOS (flake):

```nix
{
  inputs.claude-desktop.url = "github:<you>/claude-desktop-flake";
  inputs.claude-desktop.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, claude-desktop, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [({ pkgs, ... }: {
        nixpkgs.overlays = [ claude-desktop.overlays.default ];
        nixpkgs.config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "claude-desktop" "claude-desktop-unwrapped" ];
        environment.systemPackages = [ pkgs.claude-desktop ];
        # нужен для сохранения входа (Secret Service), если нет GNOME/KDE:
        services.gnome.gnome-keyring.enable = true;
      })];
    };
  };
}
```

Пакеты:

| Атрибут | Что это |
|---|---|
| `default` / `claude-desktop` | FHS-обёртка, рекомендуется |
| `claude-desktop-cowork` | то же плюс QEMU/KVM, OVMF и virtiofsd для Cowork (≈ +1.5 ГБ). Также нужны группа `kvm` и модуль `vhost_vsock` |
| `claude-desktop-unwrapped` | без FHS. Chat работает, а Code только при включённом `programs.nix-ld` |

Добавить своих пакетов в FHS (например, для MCP-серверов):
`claude-desktop.override { extraPkgs = pkgs: [ pkgs.docker-client pkgs.go ]; }`.
Внутри FHS виден и ваш обычный `PATH` (`/run/current-system/sw/bin`,
`~/.nix-profile/bin`), он стоит после `/usr/bin`.

## Wayland

С Electron 38 платформа Ozone по умолчанию `auto`, так что в Wayland-сессии приложение
и так запускается нативно. Если задан `NIXOS_OZONE_WL=1` и есть `WAYLAND_DISPLAY`,
обёртка добавляет `--ozone-platform=wayland --enable-wayland-ime=true`.
Флаг `--ozone-platform-hint=auto` не передаётся сознательно: во встроенном Electron 44
его уже нет (строки в бинаре отсутствуют). Чтобы принудительно запустить через XWayland,
выполните `claude-desktop --ozone-platform=x11`.

## Конфигурация и MCP

Всё лежит там же, где обычно: `~/.config/Claude/` (переопределяется через
`CLAUDE_USER_DATA_DIR`). MCP-серверы чата задаются в
`~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/projects"]
    }
  }
}
```

По [документации](https://code.claude.com/docs/en/desktop) вкладка Code подхватывает
эти серверы, а также `~/.claude.json` и `.mcp.json`. В FHS уже есть `node`/`npx`,
`uv`/`uvx`, `python3`, `git`, `ssh`, `bwrap` и `socat`.

## Claude Code внутри Desktop

Отдельно ставить CLI (`@anthropic-ai/claude-code` или нативный) **не нужно**, и `claude`
из `PATH` приложение не использует. В `app.asar` зашит манифест конкретной версии
(для 3.6556.2 это Claude Code **2.1.308** с sha256 для каждой платформы). При первом
использовании Desktop качает
`https://downloads.claude.ai/claude-code-releases/<ver>/linux-x64/claude.zst`, проверяет
хэш и кладёт бинарь в `~/.config/Claude/claude-code/`. Дальше он сам обновляет эту копию
(`[CCD-autoupdate]`). Это происходит во время работы приложения, а не при сборке, поэтому
Nix не отслеживает эту загрузку.

## Обновление

```sh
./update.sh          # подтянуть новую версию в package.nix
./update.sh --check  # exit 1, если есть обновление (для CI)
```

Скрипт сначала проверяет отпечаток ключа `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`,
потом GPG-подпись `InRelease`, потом SHA256 индексов `Packages`. Затем скачивает `.deb`
через `nix-prefetch-url`, сверяет хэш с подписанным индексом и переписывает блок версии
и хэшей в `package.nix`. Сборка использует только `fetchurl` с фиксированным хэшем.
Старые версии в pool пока не удаляются (в индексе 61 версия), но Anthropic этого не
обещает, поэтому старые пины однажды могут перестать скачиваться.

## Статус (3.6556.2, проверено на x86_64 NixOS)

| | |
|---|---|
| ✅ Сборка, `nix flake check` | `auto-patchelf: 0 dependencies could not be satisfied` |
| ✅ Запуск X11 (Xvfb) | окно `Claude` / `com.anthropic.Claude`, UI «Claude for Linux» отрисован |
| ✅ Запуск Wayland (headless sway) | нативный `xdg_shell`, `app_id=com.anthropic.Claude`, флаги Ozone применяются |
| ✅ `claude://` | приложение само прописывает `x-scheme-handler/claude` в `mimeapps.list`; второй запуск с URL передаёт его в работающий экземпляр (single instance) и выходит с кодом 0 |
| ✅ Бинарь Claude Code 2.1.308 в FHS | `claude --version` работает; без FHS и без nix-ld падает с `No such file or directory` |
| ✅ Keyring | Secret Service доступен из FHS: в тесте был D-Bus-активирован gnome-keyring (KWallet не проверялся) |
| ⚠️ Вход в аккаунт, работа Code-сессий, MCP | не проверялись: нужен реальный аккаунт |
| ⚠️ aarch64 | вычисляется, хэш `.deb` проверен, но собрать и запустить было не на чем |
| ⚠️ Cowork | только в `claude-desktop-cowork`; проверены симлинки OVMF, запуск ВМ не проверялся |
| ❌ Автообновление приложения | на Linux его нет и в официальной сборке (`in-app updater off (updates via apt)`). Обновлять через `./update.sh` + `nix flake update` |
| ❌ Computer Use, диктовка | нет в официальной Linux beta |
| ⚠️ Quick Entry hotkey | на Wayland нужен портал GlobalShortcuts вашего DE |

Известные ограничения FHS (bubblewrap):

- в сессиях Code не работает `sudo`, потому что включён `NoNewPrivs`;
- из `/etc` хоста видны только избранные файлы (`passwd`, `hosts`, `ssl/certs`, `resolv.conf`, …),
  а `/etc/ssh/ssh_config` и `/etc/gitconfig` не видны (`~/.ssh` и `~/.gitconfig` работают);
- если браузер ещё не запущен, `xdg-open` при входе запустит его внутри FHS-окружения
  (с урезанным `/etc` и `NoNewPrivs`). Лучше открыть браузер заранее;
- `chrome-sandbox` без SUID. Chromium использует sandbox на user namespaces (по умолчанию
  на NixOS они включены).

## Разработка

```sh
nix develop   # asar, dpkg, gnupg, curl, nixfmt
nix fmt       # nixfmt-tree (nixfmt-rfc-style теперь просто алиас nixfmt)
nix flake check
```
