<div align="center">

# Claude Desktop for NixOS

**Claude Desktop (Chat · Code · Cowork) в виде Nix flake для NixOS.**
Собирается из официального Linux-пакета Anthropic.

[![NixOS](https://img.shields.io/badge/NixOS-flake-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Claude Desktop](https://img.shields.io/badge/Claude_Desktop-3.6556.2-D97757)](https://code.claude.com/docs/en/desktop-linux)
[![Claude Code](https://img.shields.io/badge/Claude_Code-2.1.308-D97757)](https://code.claude.com/docs/en/desktop)
[![Platforms](https://img.shields.io/badge/platforms-x86__64%20%7C%20aarch64-informational)](#статус)
[![License](https://img.shields.io/badge/app_license-unfree-red)](#дисклеймер)
[![Unofficial](https://img.shields.io/badge/status-unofficial-lightgrey)](#дисклеймер)

</div>

> [!WARNING]
> **Это неофициальный репак.** Anthropic выпускает Linux-версию (beta) только для Ubuntu и Debian
> и NixOS не поддерживает. С проблемами этого флейка в поддержку Anthropic обращаться
> не нужно. Бинарей Anthropic в репозитории нет: `.deb` скачивается с `downloads.claude.ai`
> при сборке, и его хэш зафиксирован.

---

## Содержание

- [Быстрый старт](#быстрый-старт)
- [Установка](#установка)
- [Пакеты](#пакеты)
- [Как это устроено](#как-это-устроено)
- [Claude Code внутри Desktop](#claude-code-внутри-desktop)
- [MCP и конфигурация](#mcp-и-конфигурация)
- [Wayland](#wayland)
- [Обновление](#обновление)
- [Статус](#статус)
- [Ограничения](#ограничения)
- [Troubleshooting](#troubleshooting)
- [Разработка](#разработка)
- [Дисклеймер](#дисклеймер)

## Быстрый старт

```sh
nix run github:ilqqy/claude-desktop-flake
```

Разрешать unfree отдельно не нужно: флейк сам разрешает его для этого пакета.

## Установка

### NixOS (flake)

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-desktop = {
      url = "github:ilqqy/claude-desktop-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, ... }@inputs: {
    nixosConfigurations.<host> = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [ ./configuration.nix ];
    };
  };
}
```

```nix
# configuration.nix
{ pkgs, inputs, ... }:
{
  environment.systemPackages = [
    inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # Хранилище для входа в аккаунт (Secret Service). На GNOME и KDE оно уже есть.
  services.gnome.gnome-keyring.enable = true;
}
```

Затем `sudo nixos-rebuild switch`.

<details>
<summary><b>Через overlay (<code>pkgs.claude-desktop</code>)</b></summary>

```nix
{ pkgs, lib, inputs, ... }:
{
  nixpkgs.overlays = [ inputs.claude-desktop.overlays.default ];
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-desktop" "claude-desktop-unwrapped" ];

  environment.systemPackages = [ pkgs.claude-desktop ];
}
```

С overlay пакет собирается из вашего nixpkgs, поэтому unfree нужно разрешить в вашей
конфигурации, как показано выше.

</details>

<details>
<summary><b>Home Manager</b></summary>

```nix
{ pkgs, inputs, ... }:
{
  home.packages = [
    inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
```

</details>

<details>
<summary><b>Без конфигурации: <code>nix profile</code></b></summary>

```sh
nix profile add github:ilqqy/claude-desktop-flake
nix profile upgrade claude-desktop-flake   # обновить
nix profile remove claude-desktop-flake    # удалить
```

</details>

## Пакеты

| Атрибут | Описание |
|---|---|
| `default`, `claude-desktop` | приложение в FHS-окружении, **рекомендуется** |
| `claude-desktop-cowork` | то же плюс QEMU/KVM, OVMF и virtiofsd для Cowork (≈ +1.5 ГБ) |
| `claude-desktop-unwrapped` | без FHS: Chat работает, Code — только при `programs.nix-ld.enable = true` |

Для MCP-серверов в FHS можно добавить пакеты:

```nix
inputs.claude-desktop.packages.${system}.default.override {
  extraPkgs = pkgs: [ pkgs.docker-client pkgs.go ];
}
```

<details>
<summary><b>Что нужно для Cowork</b></summary>

- пакет `claude-desktop-cowork`;
- включённая аппаратная виртуализация и пользователь в группе `kvm`
  (`users.users.<you>.extraGroups = [ "kvm" ];`);
- модуль ядра `vhost_vsock` (`boot.kernelModules = [ "vhost_vsock" ];`).

</details>

## Как это устроено

```
downloads.claude.ai/claude-desktop/apt/stable          (официальный apt-репозиторий, без авторизации)
        │  fetchurl, фиксированный sha256
        ▼
claude-desktop_<ver>_<arch>.deb
        │  dpkg-deb → autoPatchelfHook          app.asar НЕ модифицируется
        ▼
claude-desktop-unwrapped                       родной Electron 44 + Linux-сборки claude-native / node-pty
        │  buildFHSEnv (bubblewrap)
        ▼
claude-desktop                                 /bin/bash, /usr/bin/*, /lib64/ld-linux, node, uv, git …
```

**Почему именно так:**

1. **Не electron из nixpkgs.** Приложение берёт локали, хелперы и образ ВМ из
   `process.resourcesPath`, а Electron вычисляет этот путь по `/proc/self/exe`. Поэтому
   используется родной Electron из `.deb`, исправленный через `autoPatchelfHook`.
2. **FHS обязателен для вкладки Code.** Desktop сам скачивает glibc-бинарь Claude Code. Кроме
   того, он вызывает `/bin/bash`, `/usr/bin/pgrep`, `/usr/bin/secret-tool` и т. п. по
   абсолютным путям. На NixOS без `nix-ld` ничего из этого не работает.
3. **Заглушки не нужны.** Раньше community-проекты (k3d3, aaddrick ≤ 2.x) пересобирали
   Windows-инсталлер и подменяли нативные модули. Теперь в официальном `.deb` они уже собраны под Linux.

## Claude Code внутри Desktop

Отдельный CLI (`@anthropic-ai/claude-code` или нативный) ставить **не нужно**, `claude` из
`PATH` Desktop не использует.

- в `app.asar` зашит манифест конкретной версии (для 3.6556.2 это **2.1.308**) с sha256 для каждой платформы;
- при первом запуске вкладки Code Desktop скачивает
  `downloads.claude.ai/claude-code-releases/<ver>/linux-x64/claude.zst`, сверяет хэш и кладёт бинарь в
  `~/.config/Claude/claude-code/`;
- дальше он сам обновляет эту копию (`[CCD-autoupdate]`). Загрузка идёт во время работы, а не при сборке,
  поэтому Nix её не отслеживает.

## MCP и конфигурация

Всё хранится в `~/.config/Claude/` (путь можно переопределить через `CLAUDE_USER_DATA_DIR`).

```jsonc
// ~/.config/Claude/claude_desktop_config.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/projects"]
    }
  }
}
```

По [документации](https://code.claude.com/docs/en/desktop) вкладка Code подхватывает эти серверы,
а также `~/.claude.json` и `.mcp.json` проекта.

В FHS уже есть `node` / `npx`, `uv` / `uvx`, `python3`, `git`, `ssh`, `bwrap` и `socat`.
Ваш обычный `PATH` (`/run/current-system/sw/bin`, `~/.nix-profile/bin`) тоже доступен:
он стоит после `/usr/bin`.

## Wayland

В Electron ≥ 38 по умолчанию `--ozone-platform=auto`, поэтому в Wayland-сессии приложение
запускается нативно. Если задан `NIXOS_OZONE_WL=1`, обёртка дополнительно передаёт:

```
--ozone-platform=wayland --enable-wayland-ime=true
```

> [!NOTE]
> `--ozone-platform-hint=auto` не передаётся сознательно: во встроенном Electron 44 такого флага
> больше нет. Чтобы запустить через XWayland, используйте `claude-desktop --ozone-platform=x11`.

## Обновление

```sh
./update.sh          # подтянуть последнюю версию в package.nix
./update.sh --check  # exit 1, если есть обновление (удобно для CI)
```

Цепочка доверия:

```
отпечаток ключа 31DD DE24 DDFA B679 F42D  7BD2 BAA9 29FF 1A7E CACE  (из документации Anthropic)
  → GPG-подпись InRelease
    → SHA256 индексов Packages
      → SHA256 .deb, который должен совпасть с результатом nix-prefetch-url
```

Скрипт переписывает только блок `# BEGIN update.sh … # END update.sh` в `package.nix`.
У пользователей флейка обновление делается так: `nix flake update claude-desktop` и rebuild.

## Статус

Проверено на `x86_64-linux` с версией 3.6556.2.

| | Что | Как проверено |
|:-:|---|---|
| ✅ | Сборка, `nix flake check` | `auto-patchelf: 0 dependencies could not be satisfied` |
| ✅ | Запуск X11 | Xvfb: окно `com.anthropic.Claude`, экран «Claude for Linux» отрисован |
| ✅ | Запуск Wayland | headless sway: нативный `xdg_shell`, флаги Ozone применяются |
| ✅ | Ссылки `claude://` | обработчик прописывается в `mimeapps.list`; второй экземпляр передаёт URL первому |
| ✅ | Claude Code 2.1.308 | в FHS `claude --version` работает; без FHS и без nix-ld получается `No such file or directory` |
| ✅ | Keyring | Secret Service доступен из FHS (gnome-keyring) |
| ⚠️ | Вход, Code-сессии, MCP | не проверялись: нужен аккаунт |
| ⚠️ | aarch64 | вычисляется, хэш проверен, но не собиралось |
| ⚠️ | Cowork | проверена только раскладка OVMF, запуск ВМ не проверялся |
| ⚠️ | Quick Entry hotkey | на Wayland нужен портал GlobalShortcuts вашего DE |
| ❌ | Автообновление приложения | на Linux его нет и в официальной сборке; обновлять через `nix flake update` |
| ❌ | Computer Use, диктовка | нет в официальной Linux beta |

## Ограничения

Это ограничения FHS-окружения (bubblewrap):

- **`sudo` в Code-сессиях не работает**, потому что установлен `NoNewPrivs`;
- **`/etc` хоста виден не целиком**: `passwd`, `hosts`, `resolv.conf`, `ssl/certs` и т. п. доступны,
  а `/etc/ssh/ssh_config` и `/etc/gitconfig` нет. `~/.ssh` и `~/.gitconfig` работают;
- если при входе браузер ещё не открыт, `xdg-open` запустит его **внутри** FHS. Лучше открыть
  браузер заранее;
- `chrome-sandbox` без SUID. Chromium использует sandbox на user namespaces, которые в NixOS
  включены по умолчанию.

## Troubleshooting

<details>
<summary><b>Вход не сохраняется, при каждом запуске просит залогиниться</b></summary>

Нужен работающий Secret Service: `services.gnome.gnome-keyring.enable = true;`. На KDE — KWallet.
При первом запуске gnome-keyring может попросить придумать пароль для нового keyring.

</details>

<details>
<summary><b>После входа в браузере не открывается приложение</b></summary>

Ссылка `claude://` должна открываться через `com.anthropic.Claude.desktop`. Пакет должен быть
установлен (через `environment.systemPackages`, Home Manager или `nix profile`), а не просто
запущен из `./result`. Проверка:

```sh
xdg-mime query default x-scheme-handler/claude   # → com.anthropic.Claude.desktop
```

</details>

<details>
<summary><b>Где логи</b></summary>

`~/.config/Claude/logs/main.log`, а также stdout, если запускать `claude-desktop` из терминала.

</details>

## Разработка

```sh
nix develop      # asar, dpkg, gnupg, curl, nixfmt
nix fmt          # nixfmt-tree
nix flake check  # сборка и проверка форматирования
```

| Файл | Назначение |
|---|---|
| `flake.nix` | `packages`, `apps`, `overlays`, `devShells`, `formatter`, `checks` |
| `package.nix` | распаковка `.deb`, `autoPatchelfHook`, Wayland-обёртка и FHS-окружение |
| `update.sh` | обновление версии и хэшей по подписанному apt-индексу |

## Дисклеймер

Claude и Claude Desktop — продукты и товарные знаки Anthropic PBC. Этот проект с Anthropic никак
не связан и ими не поддерживается. Само приложение проприетарное (`meta.license = lib.licenses.unfree`)
и распространяется только с серверов Anthropic. Linux-версия находится в beta. Пользуйтесь на свой риск.

Ссылки: [Claude Desktop on Linux](https://code.claude.com/docs/en/desktop-linux) ·
[Claude Code Desktop](https://code.claude.com/docs/en/desktop) ·
[aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) ·
[k3d3/claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake)
