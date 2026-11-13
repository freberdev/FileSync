#!/usr/bin/env bash
# Verifies that /usr/bin/rsync (openrsync on macOS) works against the real server
# with the exact flag set used by Filsynk. Usage:
#   scripts/verify-rsync-interop.sh <user@host> <identityFile>
# Server side: only writes in ~/filsynk-interop-<pid>, which is removed on exit.
set -u

if [ $# -ne 2 ]; then
  echo "usage: $0 <user@host> <identityFile>" >&2
  exit 2
fi
SERVER="$1"
IDENTITY="$2"
RSYNC=/usr/bin/rsync
UNREACHABLE=filsynk@192.0.2.1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RESULTS="$REPO_ROOT/docs/interop-results.md"

SSH_OPTS=(-o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)
ssh_cmd() { ssh -i "$IDENTITY" "${SSH_OPTS[@]}" "$SERVER" "$1"; }
# ssh with one automatic retry (first connection after idle may fail with "No route to host")
ssh_retry() { ssh_cmd "$1" 2>/dev/null || { sleep 2; ssh_cmd "$1"; }; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/filsynk-interop-local.XXXXXX")" || exit 2
REMOTE_NAME="filsynk-interop-$$"
REMOTE=""        # absolute remote path, set once created
REMOTE_HOME=""

cleanup() {
  # local: only our own mktemp dir
  case "$(basename "$WORK")" in
    filsynk-interop-local.*) rm -rf -- "$WORK" ;;
  esac
  # remote: only the resolved absolute path whose last component starts with filsynk-interop-
  # and which sits directly in the remote home directory.
  if [ -n "$REMOTE" ] && [ -n "$REMOTE_HOME" ]; then
    case "$(basename "$REMOTE")" in
      filsynk-interop-*)
        if [ "$(dirname "$REMOTE")" = "$REMOTE_HOME" ] && [ "$REMOTE" != "$REMOTE_HOME" ]; then
          ssh_cmd "case \"\$(basename '$REMOTE')\" in filsynk-interop-*) rm -rf -- '$REMOTE' ;; esac" >/dev/null 2>&1
        fi ;;
    esac
  fi
}
trap cleanup EXIT

# ---- remote working dir
REMOTE_HOME="$(ssh_retry 'cd && pwd -P')" || { echo "cannot reach server" >&2; REMOTE_HOME=""; exit 2; }
REMOTE="$(ssh_cmd "mkdir -p '$REMOTE_HOME/$REMOTE_NAME' && cd '$REMOTE_HOME/$REMOTE_NAME' && pwd -P")" \
  || { echo "cannot create remote dir" >&2; REMOTE=""; exit 2; }
echo "remote dir: $REMOTE"
echo "remote rsync: $(ssh_cmd 'rsync --version | head -1')"

# ---- local fixtures
SRC="$WORK/src"
mkdir -p "$SRC/sub" "$SRC/Mapp med mellanslag"
printf 'v1' > "$SRC/a.txt"
printf 'c'  > "$SRC/sub/c.txt"
printf 'r'  > "$SRC/Räksmörgås anteckning.txt"
printf 'd'  > "$SRC/Mapp med mellanslag/d.txt"
printf '.DS_Store\n._*\n.localized\n.Trash*\n.Spotlight-V100\n.fseventsd\n' > "$WORK/excludes.txt"

SSH_E="ssh -i $IDENTITY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"
PARTIAL=(--partial-dir=.filsynk-partial)
PARTIAL_STATUS=ok

# sync <ts> <server> <remotePath> [identity-for-ssh]
do_sync() {
  local ts="$1" srv="$2" rp="$3" e="${4:-$SSH_E}"
  "$RSYNC" -a --delete --backup "--backup-dir=$rp/Raderat/$ts" --exclude=/Raderat/ \
    "--exclude-from=$WORK/excludes.txt" ${PARTIAL[@]+"${PARTIAL[@]}"} --timeout=60 --stats \
    -e "$e" "$SRC/" "$srv:$rp/"
}

RESULT_LINES=()
FAILED=0
record() { # name PASS|FAIL detail
  RESULT_LINES+=("$1: $2 ${3:-}")
  echo "$1: $2 ${3:-}"
  [ "$2" = PASS ] || FAILED=1
}
rtest() { ssh_cmd "$1" >/dev/null 2>&1; }  # run remote test, status only
rread() { ssh_cmd "cat '$1'" 2>/dev/null; }

T1=2026-01-01_000001; T2=2026-01-01_000002; T3=2026-01-01_000003; T4=2026-01-01_000004

# ---- A
OUT="$WORK/a.out"
do_sync "$T1" "$SERVER" "$REMOTE" >"$OUT" 2>"$WORK/a.err"; A_RC=$?
if [ $A_RC -ne 0 ] && grep -q 'partial-dir' "$WORK/a.err"; then
  echo "partial-dir rejected; retrying without it"
  PARTIAL=(); PARTIAL_STATUS=rejected
  do_sync "$T1" "$SERVER" "$REMOTE" >"$OUT" 2>"$WORK/a.err"; A_RC=$?
fi
if [ $A_RC -eq 0 ] \
  && rtest "test -f '$REMOTE/a.txt' && test -f '$REMOTE/sub/c.txt' && test -f '$REMOTE/Räksmörgås anteckning.txt' && test -f '$REMOTE/Mapp med mellanslag/d.txt' && ! test -e '$REMOTE/Raderat'"; then
  record A PASS
else
  record A FAIL "(rsync rc=$A_RC) $(head -3 "$WORK/a.err" | tr '\n' ' ')"
fi

# ---- B
printf 'v2-longer' > "$SRC/a.txt"; rm "$SRC/sub/c.txt"
do_sync "$T2" "$SERVER" "$REMOTE" >"$WORK/b.out" 2>"$WORK/b.err"; B_RC=$?
if [ $B_RC -eq 0 ] \
  && [ "$(rread "$REMOTE/a.txt")" = "v2-longer" ] \
  && [ "$(rread "$REMOTE/Raderat/$T2/a.txt")" = "v1" ] \
  && rtest "test -f '$REMOTE/Raderat/$T2/sub/c.txt' && ! test -e '$REMOTE/sub/c.txt'"; then
  record B PASS
else
  record B FAIL "(rsync rc=$B_RC) $(head -3 "$WORK/b.err" | tr '\n' ' ')"
fi

# ---- C
do_sync "$T3" "$SERVER" "$REMOTE" >"$WORK/c.out" 2>"$WORK/c.err"; C_RC=$?
if [ $C_RC -eq 0 ] && rtest "! test -e '$REMOTE/Raderat/$T3' && test -f '$REMOTE/Raderat/$T2/a.txt'"; then
  record C PASS
else
  record C FAIL "(rsync rc=$C_RC) $(head -3 "$WORK/c.err" | tr '\n' ' ')"
fi

# ---- D
TOP="$(ssh_cmd "find '$REMOTE' -maxdepth 1 -name 'Räksmörgås anteckning.txt' | wc -l" 2>/dev/null | tr -d ' ')"
UNDER="$(ssh_cmd "find '$REMOTE/Raderat' -name 'Räksmörgås anteckning.txt' | wc -l" 2>/dev/null | tr -d ' ')"
if [ "$TOP" = 1 ] && [ "$UNDER" = 0 ]; then
  record D PASS
else
  record D FAIL "(top=$TOP under-Raderat=$UNDER)"
fi

# ---- E
mkdir -p "$SRC/Raderat"; printf 'x' > "$SRC/Raderat/lokal.txt"
do_sync "$T4" "$SERVER" "$REMOTE" >"$WORK/e.out" 2>"$WORK/e.err"; E_RC=$?
FOUND="$(ssh_cmd "find '$REMOTE' -name 'lokal.txt' | wc -l" 2>/dev/null | tr -d ' ')"
if [ $E_RC -eq 0 ] && [ "$FOUND" = 0 ]; then
  record E PASS
else
  record E FAIL "(rsync rc=$E_RC found=$FOUND) $(head -3 "$WORK/e.err" | tr '\n' ' ')"
fi

# ---- F: unreachable host (TEST-NET), expect connect timeout
do_sync "$T4" "$UNREACHABLE" "/home/filsynk/filsynk-interop-f" >"$WORK/f.out" 2>"$WORK/f.err"; F_RC=$?
echo "F: exit $F_RC"

# ---- G: one failed login with a throwaway key against the real server (single attempt)
ssh-keygen -q -t ed25519 -N '' -C filsynk-interop-throwaway -f "$WORK/throwaway" >/dev/null
G_SSH="ssh -i $WORK/throwaway -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"
do_sync "$T4" "$SERVER" "$REMOTE" "$G_SSH" >"$WORK/g.out" 2>"$WORK/g.err"; G_RC=$?
echo "G: exit $G_RC"

# ---- results file
{
  echo "# Interop results"
  echo
  echo "- Date: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "- Local rsync: $($RSYNC --version 2>&1 | head -1)"
  echo "- Remote rsync: $(ssh_cmd 'rsync --version | head -1' 2>/dev/null)"
  echo "- Server: $SERVER"
  echo
  echo "## Checks"
  echo
  for l in "${RESULT_LINES[@]}"; do echo "- $l"; done
  echo
  echo "partial-dir: $PARTIAL_STATUS"
  echo
  echo "## F: unreachable host ($UNREACHABLE)"
  echo
  echo "Exit code: $F_RC"
  echo
  echo '```'
  cat "$WORK/f.err"
  echo '```'
  echo
  echo "## G: rejected key (throwaway key against $SERVER)"
  echo
  echo "Exit code: $G_RC"
  echo
  echo '```'
  cat "$WORK/g.err"
  echo '```'
} > "$RESULTS"

[ "$FAILED" -eq 0 ] || { echo "Some checks FAILED"; exit 1; }
echo "All checks PASS (A-E)"
exit 0
