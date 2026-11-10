#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Scripts/Progress.command
install_started=$SECONDS
trap 'result=$?; if [[ "$result" != 0 ]]; then printf "✗ Запуск прерван через %s с\n" "$((SECONDS - install_started))" >&2; fi' EXIT
# Always build first; a stale dist bundle is never installed.
./build.command
source_app="$PWD/dist/Super Bar.app"
parent="${SUPER_BAR_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$parent" .build/modules
parent="$(cd "$parent" && pwd -P)"
dest="$parent/Super Bar.app"
stage="$(mktemp -d "$parent/.superbar-install.XXXXXXXX")"
receipt_dir="$(mktemp -d "${TMPDIR:-/tmp}/superbar-receipt.XXXXXXXX")"
receipt="$receipt_dir/launch.json"
keep_stage=0
cleanup() {
  local result=$?
  if [[ "$result" != 0 ]]; then printf "✗ Запуск прерван через %s с\n" "$((SECONDS - install_started))" >&2; fi
  if [[ "$keep_stage" == 0 ]]; then rm -rf "$stage"; else echo "Резервная копия сохранена: $stage" >&2; fi
  rm -rf "$receipt_dir"
}
trap cleanup EXIT
step "Компиляция помощника установки" xcrun swiftc -O -module-cache-path .build/modules Scripts/AppLifecycle.swift -o "$stage/lifecycle"
# Never replace an unrelated application at the destination.
if [[ -e "$dest" ]]; then
  [[ -d "$dest" ]] || { echo 'Путь установки занят другим файлом.' >&2; exit 1; }
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$id" == local.SuperBar ]] || { echo 'Путь установки занят другим приложением.' >&2; exit 1; }
fi
step "Копирование новой сборки" ditto "$source_app" "$stage/Super Bar.app"
step "Проверка подписи перед установкой" codesign --verify --deep --strict "$stage/Super Bar.app"
plist="$stage/Super Bar.app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
expected="$(shasum -a 256 "$source_app/Contents/MacOS/SuperBar" | cut -d ' ' -f 1)"
actual="$(shasum -a 256 "$stage/Super Bar.app/Contents/MacOS/SuperBar" | cut -d ' ' -f 1)"
[[ "$actual" == "$expected" ]] || { echo 'Сборка повреждена; установка отменена.' >&2; exit 1; }
step "Завершение старых панелей" "$stage/lifecycle" stop
# Existing LG configuration wins. Copy a project token once, never embed it in the app.
config="$HOME/Library/Application Support/LGBar"
if [[ "${SUPER_BAR_SKIP_TOKEN_MIGRATION:-0}" != 1 && -s token.txt ]]; then
  mkdir -p "$config"
  chmod 700 "$config"
  if [[ ! -e "$config/token.txt" ]]; then
    # noclobber protects an existing credential even if it appears concurrently.
    (umask 077; set -o noclobber; cat token.txt > "$config/token.txt")
  elif [[ ! -s "$config/token.txt" ]]; then
    echo "Файл LG token.txt в Application Support пуст. Заполни его через LG settings или убери пустой файл и повтори установку." >&2
    exit 1
  fi
fi
if [[ -d "$dest" ]]; then mv "$dest" "$stage/previous.app"; fi
if ! mv "$stage/Super Bar.app" "$dest"; then
  if [[ -d "$stage/previous.app" ]] && ! mv "$stage/previous.app" "$dest"; then
    keep_stage=1
    echo 'Не удалось восстановить прежнюю версию автоматически.' >&2
  fi
  echo 'Не удалось заменить приложение.' >&2
  exit 1
fi
rollback() {
  # Do not remove an executable while its process is still running.
  if ! step "Завершение старых панелей" "$stage/lifecycle" stop; then
    keep_stage=1
    echo 'Не удалось остановить процесс: установленная версия и резервная копия оставлены на месте.' >&2
    return 1
  fi
  rm -rf "$dest"
  if [[ -d "$stage/previous.app" ]]; then
    if ! mv "$stage/previous.app" "$dest"; then
      keep_stage=1
      echo 'Не удалось восстановить прежнюю версию автоматически.' >&2
      return 1
    fi
  fi
  echo 'Установка отменена, прежнее состояние восстановлено.' >&2
}
if ! step "Запуск и подтверждение новой версии" "$stage/lifecycle" launch "$dest" "$receipt" "$version" "$build"; then
  rollback || true
  exit 1
fi
actual="$(shasum -a 256 "$dest/Contents/MacOS/SuperBar" | cut -d ' ' -f 1)"
if [[ "$actual" != "$expected" ]]; then
  echo 'Проверка установленной сборки не прошла.' >&2
  rollback || true
  exit 1
fi
printf 'Проверены путь, версия, процесс и контрольная сумма: %s\n' "$dest"
if [[ -f "$receipt" ]]; then
  cp -p "$receipt" .build/last-launch.json || echo 'Не удалось сохранить диагностику строки меню.' >&2
fi

printf "✓ Сборка, установка и запуск целиком — %s с\n" "$((SECONDS - install_started))"
