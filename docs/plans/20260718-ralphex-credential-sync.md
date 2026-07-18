---
repo: crosscut
status: draft
depends_on: []
feature_id: ralphex-credential-sync
---
# Автоматическая синхронизация кредов для исполнителя ralphex

**Goal:** При `executor: ralphex` crosscut сам готовит и монтирует учётные данные Claude в
контейнер, вместо того чтобы падать через две секунды с непрозрачным `Not logged in`.

**Context:** `skills/crosscut/scripts/run-executor.sh` (функция `adapter_ralphex`),
`skills/crosscut/templates/crosscut.config.example.yaml`, `docs/executors.md`,
`docs/getting-started.md`, `docs/configuration.md`, `tests/` (bats).

## Проблема

Сейчас `adapter_ralphex` собирает `docker run` только из репозитория, опционального
venv-монтирования и того, что пользователь сам перечислил в `executor_options.mounts`.
Про учётные данные Claude адаптер не знает ничего.

Образ `ghcr.io/umputun/ralphex:latest` при этом ожидает их в двух местах — это видно в его
`/srv/init.sh`:

```sh
if [ -d /mnt/claude ]; then
    for f in .credentials.json settings.json settings.local.json CLAUDE.md format.sh; do
        [ -e "/mnt/claude/$f" ] && cp -L "/mnt/claude/$f" "/home/app/.claude/$f"
    done
    for d in commands skills hooks agents plugins; do
        [ -d "/mnt/claude/$d" ] && cp -rL "/mnt/claude/$d" "/home/app/.claude/"
    done
fi

# copy credentials extracted from macOS keychain (mounted separately)
if [ -f /mnt/claude-credentials.json ]; then
    cp /mnt/claude-credentials.json /home/app/.claude/.credentials.json
fi
```

Ключевое различие платформ:

- **Linux** — Claude Code хранит креды файлом `~/.claude/.credentials.json`. Монтирования
  `~/.claude:/mnt/claude` достаточно, образ подхватит их сам.
- **macOS** — креды лежат в **Keychain**, файла `.credentials.json` не существует.
  Контейнеру Keychain недоступен, поэтому их надо предварительно извлечь в файл и
  смонтировать отдельно в `/mnt/claude-credentials.json`. Именно для этого случая в образе
  и сделана вторая ветка.

**Наблюдаемый эффект без этого:** свежая установка на macOS → `/crosscut init` → запуск
ralphex → падение за 2 секунды с `error: runner: task phase: claude pattern handling:
detected error pattern: "Not logged in"`. Из сообщения невозможно понять, что требуется
монтирование; выяснить это можно только вскрыв `init.sh` внутри образа. Ни
`docs/executors.md`, ни `docs/getting-started.md`, ни пример конфига про креды не упоминают.

Дополнительный режим отказа: даже при настроенном монтировании извлечённый файл **протухает**.
Достаточно один раз извлечь креды и забыть про обновление, чтобы через несколько дней
получить тот же `Not logged in` — при внешне корректном конфиге.

## Решение

При `executor: ralphex` идти по пути синхронизации кредов **по умолчанию**, а не по явной
настройке:

1. Перед каждым `docker run` обновлять файл кредов (на macOS — из Keychain).
2. Добавлять монтирования кредов к тем, что задал пользователь, а не вместо них.
3. При невозможности подготовить креды — падать **до** запуска контейнера с сообщением,
   объясняющим что и почему.

**Существующий `executor_options.pre_run_hook` остаётся** и выполняется как и раньше —
он общий механизм, не про креды. Пользователи, уже настроившие синхронизацию через хук
и `mounts` вручную, не должны получить поломку или дублирование монтирований.

## Решения, зафиксированные заранее

**Файл кредов не удаляется после прогона.** Соблазн сузить окно его существования есть, но
crosscut запускает исполнителей **параллельно по разным репозиториям**, и удаление в конце
одного прогона выдернуло бы файл из-под другого, идущего рядом. Вместо удаления — права
`600` и путь внутри домашнего каталога пользователя.

**Имя сервиса в Keychain — `Claude Code-credentials`.** Проверено на macOS: запись
существует, значение читается `security find-generic-password -s "Claude Code-credentials" -w`.

**Извлечение только на macOS.** На Linux файл уже лежит там, где нужно; лишнее действие
только добавило бы точку отказа.

## Global Constraints

- Скрипты — bash, стиль существующего `run-executor.sh` (`set -euo pipefail`, функции-адаптеры).
- Тесты — bats, в `tests/`, по образцу существующих (`executor-lock.bats`, `config.bats`).
- Комментарии в коде — на английском.
- **Секреты не логировать.** Ни содержимое файла кредов, ни вывод `security` не должны
  попадать в `executor.log`, `stderr.log` или сообщения об ошибках.
- Обратная совместимость: конфиги, где креды уже настроены вручную через `mounts` и
  `pre_run_hook`, обязаны продолжать работать без правок.

---

### Task 1: Функция подготовки кредов

**Files:**
- Modify: `skills/crosscut/scripts/run-executor.sh`

**Produces:** `ralphex_prepare_credentials()` — печатает в stdout путь к файлу кредов,
пригодному для монтирования, либо пустую строку, если отдельный файл не нужен.

Добавить функцию рядом с `adapter_ralphex`. Поведение по платформам:

```bash
# Prepare Claude credentials for the ralphex container.
#
# The ralphex image reads credentials from two places (see its /srv/init.sh):
#   /mnt/claude/.credentials.json      — present on Linux, where Claude Code stores
#                                        credentials as a file
#   /mnt/claude-credentials.json       — the macOS path, where credentials live in the
#                                        Keychain and must be extracted first
#
# Prints the path to mount at /mnt/claude-credentials.json, or nothing when the
# platform needs no separate file. Never prints credential material.
ralphex_prepare_credentials() {
  local dest="$HOME/.claude/claude-credentials.json"

  case "$(uname -s)" in
    Darwin)
      command -v security >/dev/null 2>&1 || {
        echo "run-executor: 'security' not found; cannot read the macOS Keychain" >&2
        return 1
      }
      mkdir -p "$HOME/.claude"
      # Redirect stderr: a Keychain miss must not leak into logs beyond our own message.
      if ! security find-generic-password -s "Claude Code-credentials" -w \
           > "$dest.tmp" 2>/dev/null; then
        rm -f "$dest.tmp"
        echo "run-executor: no 'Claude Code-credentials' entry in the Keychain." >&2
        echo "  Run 'claude /login' on the host, then retry." >&2
        return 1
      fi
      # Guard against an empty read producing a valid-looking but useless file.
      [ -s "$dest.tmp" ] || {
        rm -f "$dest.tmp"
        echo "run-executor: Keychain returned an empty credential." >&2
        return 1
      }
      chmod 600 "$dest.tmp"
      mv "$dest.tmp" "$dest"
      printf '%s\n' "$dest"
      ;;
    *)
      # Linux and friends: Claude Code writes ~/.claude/.credentials.json directly,
      # and the image picks it up from the /mnt/claude mount. No extra file needed.
      [ -f "$HOME/.claude/.credentials.json" ] || {
        echo "run-executor: ~/.claude/.credentials.json not found." >&2
        echo "  Run 'claude /login' on the host, then retry." >&2
        return 1
      }
      printf '\n'
      ;;
  esac
}
```

Запись идёт через `.tmp` + `mv`, чтобы параллельный прогон не прочитал файл на середине
записи.

---

### Task 2: Подключение к adapter_ralphex с дедупликацией

**Files:**
- Modify: `skills/crosscut/scripts/run-executor.sh` — функция `adapter_ralphex`

**Consumes:** `ralphex_prepare_credentials()` (Task 1).

Сейчас монтирования собираются так:

```bash
  local EXTRA_MOUNTS=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    m="${m/#\~/$HOME}"
    EXTRA_MOUNTS+=(-v "$m")
  done < <(cfg_list executor_options.mounts)
```

Добавить перед этим сбор дефолтных монтирований кредов, а пользовательские накладывать
поверх с **дедупликацией по целевому пути в контейнере** — Docker падает при двух `-v` на
один и тот же target, а пользователь, уже настроивший креды вручную, задаст ровно те же
цели.

```bash
  # Credential mounts come first; a user-declared mount to the same container path
  # wins, so an existing manual setup keeps working unchanged.
  local CRED_FILE=""
  CRED_FILE="$(ralphex_prepare_credentials)" || return 1

  local -a MOUNT_SRC=("$HOME/.claude:/mnt/claude")
  [ -n "$CRED_FILE" ] && MOUNT_SRC+=("$CRED_FILE:/mnt/claude-credentials.json")

  while IFS= read -r m; do
    [ -n "$m" ] || continue
    MOUNT_SRC+=("${m/#\~/$HOME}")
  done < <(cfg_list executor_options.mounts)

  # Deduplicate by container target (the second colon-separated field), last wins.
  local -a EXTRA_MOUNTS=()
  local -a SEEN_TARGETS=()
  local i target dup
  for (( i=${#MOUNT_SRC[@]}-1 ; i>=0 ; i-- )); do
    target="$(printf '%s' "${MOUNT_SRC[$i]}" | cut -d: -f2)"
    dup=0
    for t in ${SEEN_TARGETS[@]+"${SEEN_TARGETS[@]}"}; do
      [ "$t" = "$target" ] && { dup=1; break; }
    done
    [ "$dup" = "1" ] && continue
    SEEN_TARGETS+=("$target")
    EXTRA_MOUNTS=(-v "${MOUNT_SRC[$i]}" ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"})
  done
```

Обход массива с конца нужен, чтобы при равных целях выигрывала **последняя** запись
(пользовательская), а порядок остальных сохранился.

Отказ `ralphex_prepare_credentials` останавливает прогон **до** `begin_run` — незачем
заводить каталог прогона и `running.json` для запуска, который заведомо не состоится.

---

### Task 3: Пример конфига и документация

**Files:**
- Modify: `skills/crosscut/templates/crosscut.config.example.yaml`
- Modify: `docs/executors.md`
- Modify: `docs/getting-started.md`

В примере конфига — в комментарии к `executor_options.mounts` указать, что для `ralphex`
монтирования кредов добавляются **автоматически** и перечислять их вручную не требуется;
`mounts` нужен только для дополнительных путей (`~/.gitconfig`, `~/.codex`,
`~/.config/ralphex` и подобных).

В `docs/executors.md`, раздел про ralphex, добавить подраздел «Учётные данные»:

- на Linux креды берутся из `~/.claude/.credentials.json`;
- на macOS извлекаются из Keychain перед каждым запуском и кладутся в
  `~/.claude/claude-credentials.json` с правами `600`;
- **файл остаётся на диске между прогонами** — сознательное решение, потому что удаление
  ломало бы параллельные прогоны; кто это считает неприемлемым, пусть переключается на
  исполнителя `codex`, который работает на хосте без контейнера;
- предусловие — выполненный `claude /login` на хосте.

В `docs/getting-started.md` — одна строка в предусловиях: для `executor: ralphex` нужен
Docker и выполненный `claude /login`.

---

### Task 4: Тесты

**Files:**
- Create: `tests/ralphex-credentials.bats`

По образцу существующих bats-тестов. Docker при этом **не запускается** — проверяется
формирование команды через уже существующий режим `DRYRUN=1` в `run-executor.sh`.

Случаи:

1. **Дедупликация.** `executor_options.mounts` содержит `~/.claude:/mnt/claude` — в
   собранной команде цель `/mnt/claude` встречается ровно один раз, и источником выступает
   пользовательское значение.
2. **Дефолт без конфига.** `mounts` пуст — в команде присутствует `-v <...>:/mnt/claude`.
3. **Дополнительные монтирования сохраняются.** `mounts` содержит
   `~/.gitconfig:/home/app/.gitconfig:ro` — оно есть в команде вместе с кредами.
4. **Отсутствие кредов останавливает прогон.** Подменить `HOME` на пустой каталог; на
   Linux-раннере это даёт ветку «файла нет» → ненулевой код возврата, сообщение содержит
   `claude /login`, каталог прогона **не создан**.
5. **Секреты не в выводе.** Записать в файл кредов заведомую строку-маркер и убедиться, что
   она не встречается ни в stdout, ни в stderr при `DRYRUN=1`.

Тест 5 — не формальность: это единственная проверка, которая поймает случайное
`echo "$CRED_FILE_CONTENTS"` при будущих правках.

Платформенную ветку macOS на Linux-CI прогнать нельзя; ветвление по `uname -s` вынести так,
чтобы его можно было подменить переменной окружения в тестах, либо явно пометить эти
случаи как выполняемые только на macOS.
