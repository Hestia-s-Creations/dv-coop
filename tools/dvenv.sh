# Sourced by dev2.sh / dev3.sh. Finds the game and its user data on Windows (Git Bash) or Linux,
# and starts instances with their own user data dir.
#   DV_GAME  game folder (holds the Delta-V binary and mods/)
#   DV_DATA  folder that holds dV/ for the main instance (Windows: ~/dvcoop-data, a copy of %APPDATA%/dV)
#   DV_INST  where the extra instances' data dirs go

FLATPAK_STEAM="$HOME/.var/app/com.valvesoftware.Steam"
GAME_DIR="dV Rings of Saturn"

DV_PY=python; command -v python >/dev/null || DV_PY=python3

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) DV_OS=windows ;;
  *)                    DV_OS=linux ;;
esac

if [ -z "$DV_GAME" ]; then
  for d in "/c/Program Files (x86)/Steam/steamapps/common/$GAME_DIR" \
           "$FLATPAK_STEAM/.local/share/Steam/steamapps/common/$GAME_DIR" \
           "$HOME/.local/share/Steam/steamapps/common/$GAME_DIR"; do
    [ -d "$d" ] && DV_GAME="$d" && break
  done
fi
[ -d "$DV_GAME" ] || { echo "game folder not found; set DV_GAME" >&2; exit 1; }

# Flatpak Steam: the game has to run inside the running Steam client's own sandbox. A separate
# `flatpak run` sandbox can't see the client; SteamAPI fails with a fatal assert and has crashed Steam.
case "$DV_GAME" in "$FLATPAK_STEAM"/*) DV_FLATPAK=1 ;; *) DV_FLATPAK= ;; esac

if [ "$DV_OS" = windows ]; then
  DV_EXE="$DV_GAME/Delta-V.exe"
  # Dev instances never use the real %APPDATA%\dV: the main one gets a copy, made on first use.
  DV_DATA="${DV_DATA:-$HOME/dvcoop-data}"
  if [ ! -d "$DV_DATA/dV" ]; then
    mkdir -p "$DV_DATA/dV"
    for f in "$APPDATA/dV"/*; do [ "$(basename "$f")" = logs ] || cp -r "$f" "$DV_DATA/dV/"; done
  fi
  DV_INST="${DV_INST:-$HOME/AppData/Local/Temp}"
else
  DV_EXE="$(find "$DV_GAME" -maxdepth 1 -type f -name 'Delta-V*' ! -name '*.pck' ! -name '*.exe' | head -1)"
  [ -x "$DV_EXE" ] || { echo "no Linux Delta-V binary in $DV_GAME" >&2; exit 1; }
  if [ -z "$DV_DATA" ]; then
    # user:// is $XDG_DATA_HOME/dV; games started by Flatpak Steam use the first one
    for d in "$FLATPAK_STEAM/.local/share" "$FLATPAK_STEAM/data" "$HOME/.local/share"; do
      [ -d "$d/dV" ] && DV_DATA="$d" && break
    done
  fi
  [ -d "$DV_DATA/dV" ] || { echo "no dV user data found; launch the game once through Steam, or set DV_DATA" >&2; exit 1; }
  # under $FLATPAK_STEAM so the sandbox can see it (its /tmp is private)
  DV_INST="${DV_INST:-${DV_FLATPAK:+$FLATPAK_STEAM/dvcoop}}"
  DV_INST="${DV_INST:-/tmp}"
fi

# dv_seed <data root>: copy the main instance's saves and settings (not logs) into another data root
dv_seed() {
  mkdir -p "$1/dV"
  for f in "$DV_DATA/dV"/*; do b=$(basename "$f"); [ "$b" = "logs" ] && continue; cp -r "$f" "$1/dV/"; done
}

# dv_clear_logs <data root>...
dv_clear_logs() {
  for r in "$@"; do rm -f "$r/dV/logs"/dv_log_*.txt "$r/dV/logs/engine_log.txt"; done
}

# dv_steam_instance: instance id of the Flatpak sandbox running the Steam client itself
# (Steam also starts helper sandboxes for its runtime and web helper; those don't count)
dv_steam_instance() {
  flatpak ps --columns=instance,child-pid,application | while read -r i c a; do
    [ "$a" = com.valvesoftware.Steam ] || continue
    case "$(ps -o args= -p "$c")" in *" -- steam"*) echo "$i"; break ;; esac
  done
}

# dv_launch <data root, or "" for the main one> <game args...>: start one instance in the background
dv_launch() {
  local root="$1"; shift
  cd "$DV_GAME"
  if [ "$DV_OS" = windows ]; then
    ( APPDATA="$(cygpath -w "${root:-$DV_DATA}")" "$DV_EXE" "$@" >/dev/null 2>&1 & )
  elif [ -n "$DV_FLATPAK" ]; then
    local inst; inst="$(dv_steam_instance)"
    [ -n "$inst" ] || { echo "Flatpak Steam is not running; start it and log in first" >&2; exit 1; }
    # flatpak enter starts with an almost empty environment, so pass what the game and SteamAPI need
    ( flatpak enter "$inst" env HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DISPLAY="$DISPLAY" \
        XDG_DATA_HOME="${root:-$DV_DATA}" sh -c 'cd "$1" && shift && exec "$@"' sh "$DV_GAME" "$DV_EXE" "$@" \
        >/dev/null 2>&1 & )
  else
    ( XDG_DATA_HOME="${root:-$DV_DATA}" "$DV_EXE" "$@" >/dev/null 2>&1 & )
  fi
  cd - >/dev/null
}

# One game install, several people working: dev2/dev3 take this lock before building (the build replaces
# mods/dv-coop.zip) and tools/stop.sh releases it. DV_WHO names the holder in the "busy" message.
DV_LOCK="${DV_LOCK:-$HOME/.dvcoop-gamelock}"
dv_lock() {
  if mkdir "$DV_LOCK" 2>/dev/null; then
    echo "${DV_WHO:-$(pwd)} $(date +%H:%M:%S)" > "$DV_LOCK/owner"
  else
    echo "game busy, held by: $(cat "$DV_LOCK/owner" 2>/dev/null). Wait, or run tools/stop.sh if it's yours." >&2
    exit 2
  fi
}
