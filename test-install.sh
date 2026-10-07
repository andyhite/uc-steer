#!/bin/sh
# Runs the real install.sh against stubbed tools in a temp dir (app path rewritten there). Never touches /Applications.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
apps="$t/Apps"
log="$t/log"
bin="$t/bin"
mkdir -p "$bin" "$t/repo/Sources"
cp "$src/Info.plist" "$t/repo/"
echo x > "$t/repo/Sources/a.swift"
sed "s|^app=.*|app=$apps/uc-steer.app|" "$src/install.sh" > "$t/repo/install.sh"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$bin/$1"; }
stub pkill "echo pkill >> '$log'; [ \"\${FAIL:-}\" != signal ] || kill -TERM \$PPID; exit 1"
stub pgrep "exit 1"
stub security 'echo "\"uc-steer dev\""'
stub codesign '[ "${FAIL:-}" != sign ]'
stub swiftc '[ "${FAIL:-}" != build ] || exit 1; for a; do o=$a; done; mkdir -p "$(dirname "$o")"; echo new > "$o"'
stub cp 'for a; do l=$a; done; case "${FAIL:-}:$1:$l" in stage:-R:*/new) exit 1;; esac; exec /bin/cp "$@"'
stub open "echo open >> '$log'; [ \"\${FAIL:-}\" != open ] && [ \"\${FAIL:-}\" != restore ]"
# FAIL=backup: moving app into stage/old fails. FAIL=swap: moving stage/new into place fails. FAIL=restore: moving stage/old back fails.
stub mv 'case "${FAIL:-}:$1:$2" in backup:*:*/old|swap:*/new:*|restore:*/old:*) exit 1;; esac; exec /bin/mv "$@"'
chmod +x "$bin"/*

fail() { echo "FAIL: $1"; [ ! -f "$t/output" ] || cat "$t/output"; exit 1; }
reset() { rm -rf "$apps" "$log"; mkdir -p "$apps/uc-steer.app"; echo old > "$apps/uc-steer.app/v"; : > "$log"; }
run() { (cd "$t/repo" && PATH="$bin:$PATH" sh install.sh "$@") >"$t/output" 2>&1; }
untouched() { [ "$(cat "$apps/uc-steer.app/v")" = old ] || fail "$1: old app not intact"; }
clean() { [ "$(ls -A "$apps")" = uc-steer.app ] || fail "$1: leftovers"; }

# Failures before the old app is stopped: untouched, never stopped.
for f in build sign stage; do
    reset; FAIL=$f run && fail "$f: expected failure"
    untouched $f; clean $f
    ! grep -q pkill "$log" || fail "$f: old app was stopped"
    [ "$f" != stage ] || [ -e "$t/repo/build/uc-steer.app/Contents/MacOS/uc-steer" ] || fail "stage: failed before the staging copy"
done

# Failures after stop: old restored and reopened.
for f in backup swap open; do
    reset; FAIL=$f run && fail "$f: expected failure"
    untouched $f; clean $f
    grep -q pkill "$log" || fail "$f: app not stopped"
    grep -q open "$log" || fail "$f: old app not reopened"
done

# Signal while stopping the old app: old intact and reopened.
reset; FAIL=signal run && fail "signal: expected failure"
untouched signal; clean signal
grep -q open "$log" || fail "signal: old app not reopened"

# Fresh install (no previous app) with open failure: failed app removed.
reset; rm -rf "$apps/uc-steer.app"; FAIL=open run && fail "fresh: expected failure"
[ -z "$(ls -A "$apps")" ] || fail "fresh: failed app or leftovers remain"

# Restore itself fails: backup must be kept.
reset; FAIL=restore run && fail "restore: expected failure"
[ "$(cat "$apps"/.uc-steer.*/old/v)" = old ] || fail "restore: backup lost"
unset FAIL # POSIX sh preserves assignments made before a shell-function call.

reset; run || fail "install"
[ -e "$apps/uc-steer.app/Contents/MacOS/uc-steer" ] || fail "not installed"
clean install

run uninstall
[ ! -e "$apps/uc-steer.app" ] || fail "uninstall"
echo ok
