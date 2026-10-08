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
# Fake process table $PROCS ("uid name" lines); pkill/pgrep honor -U like the real ones.
parse='u=; n=; while [ $# -gt 0 ]; do case $1 in -U) u=$2; shift;; -x) ;; *) n=$1;; esac; shift; done'
stub pkill "$parse"'
echo pkill >> '"'$log'"'
[ "${FAIL:-}" != signal ] || { kill -TERM $PPID; exit 1; }
[ "${FAIL:-}" != hang ] || exit 0
awk -v u="$u" -v n="$n" "!((u==\"\"||\$1==u) && \$2==n)" "$PROCS" > "$PROCS.x"; /bin/mv "$PROCS.x" "$PROCS"'
stub pgrep "$parse"'
awk -v u="$u" -v n="$n" "(u==\"\"||\$1==u) && \$2==n {f=1} END{exit !f}" "$PROCS"'
stub security 'echo "\"uc-steer dev\""'
stub sleep 'exit 0'
stub codesign '[ "${FAIL:-}" != sign ]'
stub swiftc '[ "${FAIL:-}" != build ] || exit 1; for a; do o=$a; done; mkdir -p "$(dirname "$o")"; echo new > "$o"'
stub cp 'for a; do l=$a; done; case "${FAIL:-}:$1:$l" in stage:-R:*/new) exit 1;; esac; exec /bin/cp "$@"'
# open logs which app it opened: old (has file v) or new. FAIL=open|rollsig|restore fail only opening the new app.
stub open 'if [ -f "$1/v" ]; then k=old; else k=new; fi; echo "open $k" >> '"'$log'"'; [ "$k" = old ] || [ -z "${FAIL:-}" ] || case "$FAIL" in open|rollsig|restore) exit 1;; esac'
# FAIL=backup: moving app into stage/old fails. FAIL=swap: moving stage/new into place fails. FAIL=restore: moving stage/old back fails.
# FAIL=rollsig: restoring stage/old back is hit by repeated TERM, then proceeds.
stub mv 'case "${FAIL:-}:$1:$2" in backup:*:*/old|swap:*/new:*|restore:*/old:*) exit 1;; rollsig:*/old:*) kill -TERM $PPID; kill -TERM $PPID; kill -HUP $PPID;; esac; exec /bin/mv "$@"'
chmod +x "$bin"/*

fail() { echo "FAIL: $1"; [ ! -f "$t/output" ] || cat "$t/output"; exit 1; }
reset() { rm -rf "$apps" "$log"; mkdir -p "$apps/uc-steer.app"; echo old > "$apps/uc-steer.app/v"; : > "$log"; echo "$(id -u) uc-steer" > "$t/procs"; }
run() { (cd "$t/repo" && PROCS="$t/procs" PATH="$bin:$PATH" sh install.sh "$@") >"$t/output" 2>&1; }
untouched() { [ "$(cat "$apps/uc-steer.app/v")" = old ] || fail "$1: old app not intact"; }
clean() { [ "$(ls -A "$apps")" = uc-steer.app ] || fail "$1: leftovers"; }

# Failures before the old app is stopped: untouched, never stopped.
for f in build sign stage; do
    reset; FAIL=$f run && fail "$f: expected failure"
    untouched $f; clean $f
    ! grep -q pkill "$log" || fail "$f: old app was stopped"
    [ "$f" != stage ] || [ -e "$t/repo/build/uc-steer.app/Contents/MacOS/uc-steer" ] || fail "stage: failed before the staging copy"
done

# Failures after stop: old restored and, last of all, reopened (new never opened except in the open case).
for f in backup swap open rollsig; do
    reset; FAIL=$f run && fail "$f: expected failure"
    untouched $f; clean $f
    grep -q pkill "$log" || fail "$f: app not stopped"
    [ "$(tail -n1 "$log")" = "open old" ] || fail "$f: old app not reopened last"
    case $f in open|rollsig) ;; *) ! grep -q "open new" "$log" || fail "$f: new app opened";; esac
done
grep -q "open new" "$log" || fail "rollsig: new app not opened before rollback"

# Old app that never quits: bounded wait fails, old intact and reopened, never swapped.
reset; FAIL=hang run && fail "hang: expected failure"
untouched hang; clean hang
[ "$(tail -n1 "$log")" = "open old" ] || fail "hang: old app not reopened"
! grep -q "open new" "$log" || fail "hang: new app opened"
unset FAIL # a FAIL assigned before a function call persists in POSIX sh

# Another user's uc-steer is neither killed nor waited on.
reset; echo "99999 uc-steer" >> "$t/procs"; run || fail "other user: install failed"
grep -qx "99999 uc-steer" "$t/procs" || fail "other user's process was killed"
! grep -qx "$(id -u) uc-steer" "$t/procs" || fail "own process not killed"

# Signal while stopping the old app: old intact and reopened.
reset; FAIL=signal run && fail "signal: expected failure"
untouched signal; clean signal
grep -q "open old" "$log" || fail "signal: old app not reopened"

# Fresh install (no previous app) with open failure: failed app removed.
reset; rm -rf "$apps/uc-steer.app"; FAIL=open run && fail "fresh: expected failure"
[ -z "$(ls -A "$apps")" ] || fail "fresh: failed app or leftovers remain"

# Restore itself fails: backup must be kept.
reset; FAIL=restore run && fail "restore: expected failure"
[ "$(cat "$apps"/.uc-steer.*/old/v)" = old ] || fail "restore: backup lost"
unset FAIL # POSIX sh preserves assignments made before a shell-function call.

reset; run || fail "install"
[ -e "$apps/uc-steer.app/Contents/MacOS/uc-steer" ] || fail "not installed"
[ "$(tail -n1 "$log")" = "open new" ] || fail "install: new app not opened"
! grep -q "open old" "$log" || fail "install: old app reopened"
clean install

run uninstall
[ ! -e "$apps/uc-steer.app" ] || fail "uninstall"
echo ok
