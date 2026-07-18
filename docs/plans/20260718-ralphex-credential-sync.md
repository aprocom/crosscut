---
repo: crosscut
status: validated
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

**Тонкость с порядком.** Хук выполняется **после** `begin_run`, а авто-подготовка кредов —
до него. Значит хук, который сам создаёт файл кредов, уже не успел бы спасти запуск, если
бы авто-подготовка была безусловной: она упала бы раньше. Отсюда правило — **объявленное
пользователем монтирование в credential-цель отключает авто-подготовку**. Конфиг, где
креды готовит хук, продолжает работать ровно как раньше, а не ломается на ровном месте.

## Решения, зафиксированные заранее

**Файл кредов не удаляется после прогона.** Соблазн сузить окно его существования есть, но
crosscut запускает исполнителей **параллельно по разным репозиториям**, и удаление в конце
одного прогона выдернуло бы файл из-под другого, идущего рядом. Вместо удаления — права
`600` и путь внутри домашнего каталога пользователя.

**Имя сервиса в Keychain — `Claude Code-credentials`.** Проверено на macOS: запись
существует, значение читается `security find-generic-password -s "Claude Code-credentials" -w`.

**Извлечение только на macOS.** На Linux файл уже лежит там, где нужно; лишнее действие
только добавило бы точку отказа.

## Что учесть при приёмке

**Скилл — симлинк на этот репозиторий.** `~/.claude/skills/crosscut` указывает на
`skills/crosscut` рабочего дерева. Во время прогона это безопасно: исполнитель работает в
отдельном git-worktree и основного дерева не касается. Но **merge меняет инструмент под
собой** — следующий же запуск исполнителя пойдёт по новому коду. Поэтому после мержа
обязателен дымовой прогон `EXECUTOR_DRYRUN=1` на реальном конфиге, до любого настоящего
запуска.

**Существующий обходной путь в конфиге владельца.** Сейчас в `~/.crosscut/crosscut.config.yaml`
креды настроены вручную: `executor_options.pre_run_hook: refresh-claude-creds` и два
монтирования (`~/.claude:/mnt/claude`, `~/.claude/claude-credentials.json:/mnt/claude-credentials.json`).
После этой задачи они станут избыточными, но **ломать ничего не должны** — ровно это и
проверяет дедупликация из Task 2 и тест 1 из Task 4. Чистка конфига — отдельное решение
владельца, в объём задачи не входит.

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

- [x] Add `ralphex_prepare_credentials()` to `skills/crosscut/scripts/run-executor.sh`

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

  # Overridable so the platform branch stays testable on either OS (see Task 4).
  case "${CROSSCUT_UNAME:-$(uname -s)}" in
    Darwin)
      command -v security >/dev/null 2>&1 || {
        echo "run-executor: 'security' not found; cannot read the macOS Keychain" >&2
        return 1
      }
      mkdir -p "$HOME/.claude"

      # A unique temp file, not "$dest.tmp": runs proceed in parallel across repos, and
      # a shared temp name means one run's mv steals another's write — or finds the file
      # already gone. mktemp in the destination directory keeps the mv atomic.
      local tmp
      tmp="$(mktemp "$HOME/.claude/.claude-credentials.XXXXXX")" || {
        echo "run-executor: cannot create a temp file in ~/.claude" >&2
        return 1
      }
      # 600 before anything is written: a plain redirect would briefly leave the secret
      # world-readable under the default umask 022.
      chmod 600 "$tmp"

      # Redirect stderr: a Keychain miss must not leak into logs beyond our own message.
      if ! security find-generic-password -s "Claude Code-credentials" -w \
           > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "run-executor: no 'Claude Code-credentials' entry in the Keychain." >&2
        echo "  Run 'claude /login' on the host, then retry." >&2
        return 1
      fi
      # Guard against an empty read producing a valid-looking but useless file.
      [ -s "$tmp" ] || {
        rm -f "$tmp"
        echo "run-executor: Keychain returned an empty credential." >&2
        return 1
      }
      mv "$tmp" "$dest"
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

Запись идёт через уникальный `mktemp` + `mv`, чтобы параллельный прогон не прочитал файл
на середине записи и чтобы два прогона не подрались за общее временное имя.

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

**Разделение «посчитать путь» и «создать файл».** Сборка команды обязана оставаться
свободной от побочных эффектов: `EXECUTOR_DRYRUN=1` выходит **до** запуска контейнера, и
если извлечение кредов встанет раньше этого выхода, сухой прогон начнёт лезть в Keychain и
требовать реальную авторизацию. Существующие dry-run тесты (`tests/run-executor.bats`)
сломаются, а сама идея «показать команду, ничего не делая» перестанет выполняться.

Поэтому путь к файлу вычисляется **чисто** (`ralphex_credential_paths`), а материализация
(`ralphex_prepare_credentials` из Task 1) вызывается **после** dry-run-выхода и **до**
`begin_run`.

```bash
  # Pure: prints the mount specs credentials need, creating nothing. Safe under dry-run.
  ralphex_credential_paths() {
    printf '%s\n' "$HOME/.claude:/mnt/claude"
    case "${CROSSCUT_UNAME:-$(uname -s)}" in
      Darwin) printf '%s\n' "$HOME/.claude/claude-credentials.json:/mnt/claude-credentials.json" ;;
    esac
  }
```

Сборка монтирований в `adapter_ralphex`:

```bash
  # Credential mounts go first so that a user-declared mount to the same container
  # target overrides them: an existing manual setup keeps working unchanged.
  local -a MOUNT_SRC=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    MOUNT_SRC+=("$m")
  done < <(ralphex_credential_paths)

  local -a USER_TARGETS=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    m="${m/#\~/$HOME}"
    MOUNT_SRC+=("$m")
    USER_TARGETS+=("$(mount_target "$m")")
  done < <(cfg_list executor_options.mounts)

  # Deduplicate by container target, last wins.
  local -a EXTRA_MOUNTS=()
  local -a SEEN_TARGETS=()
  local i target dup t
  for (( i=${#MOUNT_SRC[@]}-1 ; i>=0 ; i-- )); do
    target="$(mount_target "${MOUNT_SRC[$i]}")"
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

Разбор цели вынести в функцию — не ради хитрого парсинга, а чтобы правило было записано
в одном месте вместе с обоснованием:

```bash
# Container target of a "src:target[:options]" mount spec.
#
# The second colon-separated field. executor_options.mounts is documented as
# "src:target[:options]", and within that format -v splits on colons into two or three
# fields — so a source path containing a colon is not expressible at all (that is what
# --mount exists for) and field 2 is unambiguously the target.
#
# Scope note: this does NOT hold for every -v form docker accepts. "-v /container/cache"
# declares an anonymous volume whose target is field 1. crosscut does not support that
# form in executor_options.mounts; if it ever does, this function must be revisited.
mount_target() {
  printf '%s\n' "$1" | cut -d: -f2
}

# 0 when <needle> is among the remaining arguments.
#
# set -u safe by contract: callers pass arrays as ${arr[@]+"${arr[@]}"}, so an empty
# array expands to no arguments at all rather than to an empty string.
target_declared() {
  local needle="$1"
  shift
  local t
  for t in "$@"; do
    [ "$t" = "$needle" ] && return 0
  done
  return 1
}
```

**Материализация — только для реального запуска.** После блока dry-run и перед `begin_run`:

```bash
  # Only now, past the dry-run exit: preparing credentials is a side effect and must
  # not happen while merely printing the command.
  #
  # The rule is per-target, not "the user touched credentials somewhere": preparation
  # is owed exactly when OUR default mount for the extracted file survived dedup. If
  # the user redeclared /mnt/claude-credentials.json, their source is mounted and their
  # setup (often a pre_run_hook writing that file) owns it — extracting on top would
  # break a config that works today.
  #
  # Checking the wrong target would be worse than not checking: a user who only
  # overrides /mnt/claude on macOS would silently disable the Keychain extraction while
  # the default /mnt/claude-credentials.json mount stays in the command, pointing at a
  # file that may not exist. Docker then creates a DIRECTORY at that path, the image's
  # "[ -f /mnt/claude-credentials.json ]" test fails, and we are back to
  # "Not logged in" — with one more layer of indirection hiding why.
  #
  # Which target carries the credentials differs by platform, so the check does too.
  local cred_target
  case "${CROSSCUT_UNAME:-$(uname -s)}" in
    Darwin) cred_target="/mnt/claude-credentials.json" ;;   # the extracted file
    *)      cred_target="/mnt/claude" ;;                     # the ~/.claude directory
  esac

  if ! target_declared "$cred_target" ${USER_TARGETS[@]+"${USER_TARGETS[@]}"}; then
    ralphex_prepare_credentials >/dev/null || return 1
  fi
```

Отказ подготовки останавливает прогон **до** `begin_run` — незачем заводить каталог
прогона и `running.json` для запуска, который заведомо не состоится.

---

### Task 3: Пример конфига и документация

**Files:**
- Modify: `skills/crosscut/templates/crosscut.config.example.yaml`
- Modify: `docs/executors.md`
- Modify: `docs/getting-started.md`
- Modify: `docs/configuration.md` — в описании `executor_options.mounts` отметить, что для
  `ralphex` монтирования кредов добавляются автоматически, а объявленное пользователем
  монтирование в ту же цель их перекрывает и отключает авто-подготовку

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
- Modify: `tests/run-executor.bats` — обновить ожидания существующих ralphex dry-run кейсов
  под новые монтирования кредов и выставить в них `CROSSCUT_UNAME`

По образцу существующих bats-тестов. Docker при этом **не запускается** — проверяется
формирование команды через уже существующий режим, включаемый переменной окружения
**`EXECUTOR_DRYRUN=1`** (внутри скрипта она читается в `DRYRUN`; в тестах выставлять
именно `EXECUTOR_DRYRUN`). Режим печатает команду и выходит **до** `begin_run`, поэтому
по факту создания каталога прогона можно отличить «упало до запуска» от «запустилось».

**Подготовка окружения.** Dry-run по новому дизайну **не** трогает креды — команда
собирается из чистого `ralphex_credential_paths`. Но платформа всё равно влияет на состав
монтирований (на Darwin добавляется второе), поэтому **каждый** тест обязан выставлять
`CROSSCUT_UNAME` явно. Без этого набор монтирований будет разным на машине разработчика и
на CI, и тест начнёт то падать, то проходить в зависимости от того, где запущен.

`setup()` создаёт временный `HOME` и в нём `~/.claude/.credentials.json`-пустышку — она
нужна тестам, доходящим до материализации, и не мешает остальным.

**Регрессия существующих тестов.** `tests/run-executor.bats` уже содержит dry-run проверки
ralphex (в том числе на точный состав `docker run`). Новые монтирования кредов изменят
ожидаемую команду. Эти тесты **обязаны быть обновлены в рамках этой задачи**, а не
оставлены падать: пройтись по всем ralphex-кейсам в файле и дополнить ожидания.

Случаи:

1. **Дедупликация.** `executor_options.mounts` содержит `~/.claude:/mnt/claude` — в
   собранной команде цель `/mnt/claude` встречается ровно один раз, и источником выступает
   пользовательское значение.
2. **Дефолт без конфига.** `mounts` пуст — в команде присутствует `-v <...>:/mnt/claude`.
3. **Дополнительные монтирования сохраняются.** `mounts` содержит
   `~/.gitconfig:/home/app/.gitconfig:ro` — оно есть в команде вместе с кредами.
4. **Отсутствие кредов останавливает прогон.** `CROSSCUT_UNAME=Linux`, `HOME` — пустой
   каталог **без** файла кредов, **без** `EXECUTOR_DRYRUN` → ненулевой код возврата,
   сообщение содержит `claude /login`, каталог прогона **не создан**.
5. **Секреты не в выводе.** Записать в файл кредов заведомую строку-маркер и убедиться, что
   она не встречается ни в stdout, ни в stderr.
6. **Dry-run ничего не создаёт.** `CROSSCUT_UNAME=Darwin`, `security` подменён заглушкой,
   `EXECUTOR_DRYRUN=1` → команда напечатана, заглушка **не вызывалась**, файла
   `~/.claude/claude-credentials.json` не появилось. Это и есть проверка, что сборка
   команды осталась без побочных эффектов.
7. **Пользовательские креды отключают авто-подготовку.** `mounts` содержит
   `/tmp/mycreds:/mnt/claude-credentials.json`, `CROSSCUT_UNAME=Darwin`, `security`
   подменён заглушкой → прогон не требует Keychain, заглушка не вызывалась, в команде
   стоит пользовательский источник.
7a. **Переопределение чужой цели авто-подготовку НЕ отключает.** `CROSSCUT_UNAME=Darwin`,
   `mounts` содержит только `/tmp/mydir:/mnt/claude` → заглушка `security` **вызвана**,
   файл кредов создан. Это защита от тихой поломки: иначе дефолтное монтирование
   `/mnt/claude-credentials.json` осталось бы в команде, указывая на несуществующий
   файл, а Docker создал бы на его месте каталог.
7b. **Linux: переопределение `/mnt/claude` отключает проверку.** `CROSSCUT_UNAME=Linux`,
   `HOME` без `~/.claude/.credentials.json`, `mounts` содержит
   `/tmp/mydir:/mnt/claude` → прогон **не** падает с «кредов нет»: пользователь
   смонтировал свой каталог, и требовать наш файл поверх нечего.
8. **Darwin-ветка извлекает и защищает.** `CROSSCUT_UNAME=Darwin`, заглушка `security`
   печатает маркер, без dry-run → файл создан с правами `600`, маркера нет ни в stdout,
   ни в stderr.
9. **Разбор цели.** `mount_target` на трёх входах:
   `/src:/mnt/x` → `/mnt/x` (две части);
   `/src:/mnt/x:ro` → `/mnt/x` (с опцией);
   `/src:/mnt/creds.json:cached` → `/mnt/creds.json` (опция вне набора ro/rw — поле всё
   равно второе, потому что цель определяется позицией, а не содержимым).

**Что нужно тестам 4, 7, 8 (не dry-run).** Они доходят до кода после сборки команды,
поэтому фикстура-репозиторий должна иметь **хотя бы один коммит** — иначе прогон упрётся
в `git rev-parse HEAD`, и тест упадёт не по той причине, по которой задуман. Текущий
`setup()` в `tests/run-executor.bats` репозиторий не коммитит, так что для новых тестов
нужна своя фикстура: `git init` + пустой коммит.

**Заглушка `docker` в `PATH` нужна всем тестам, где подготовка проходит успешно** — то
есть 7, 7a, 7b и 8. После успешной подготовки управление идёт дальше в `begin_run` и
затем в `docker run`; без заглушки набор тестов дёрнет настоящий Docker, вопреки
требованию «Docker не запускается». Заглушка печатает аргументы и выходит с нулём — по
её выводу заодно проверяется итоговый состав монтирований.

Единственный тест без заглушки — **4**: он падает на отсутствии кредов раньше, чем дело
дойдёт до контейнера, и именно отсутствие каталога прогона в нём и проверяется.

Тесты 5 и 8 — не формальность: это единственные проверки, которые поймают случайное
`echo "$CRED_FILE_CONTENTS"` при будущих правках.

**Платформенная ветка.** Keychain на Linux-CI не воспроизвести, поэтому ветвление берёт
платформу из переопределяемой переменной:

```bash
# Overridable so the platform branch is testable on either OS.
CROSSCUT_UNAME="${CROSSCUT_UNAME:-$(uname -s)}"
```

В `ralphex_prepare_credentials` использовать `case "$CROSSCUT_UNAME" in`. Тест на
macOS-ветку выставляет `CROSSCUT_UNAME=Darwin` и подменяет `security` заглушкой в `PATH`,
печатающей маркерную строку, — так проверяются и извлечение, и отсутствие утечки.
