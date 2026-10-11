#!/usr/bin/env bash
# Run N instances (2-5) in a private headless display, without Steam, on Linux.
#   - display :99 is a private Xvnc (Unix socket only, mode 0600, no TCP); nothing shows on the desktop
#   - the game is a hard-linked copy with its own mods/, so builds never touch the Steam install
#   - each instance gets its own HOME and XDG_DATA_HOME, so SteamAPI finds no client (no cloud sync,
#     no risk to the running Steam) and saves stay inside the sandbox
# Instance 1 is the ENet server; instance k dives (k-1)*5,000 px off. Stop with: tools/sandbox.sh stop
# Usage: tools/sandbox.sh [count] [save-dir]     save-dir defaults to the game's Flatpak Steam user data
set -e
cd "$(dirname "$0")/.."
SB="${DV_SANDBOX:-$HOME/.local/share/dvcoop-sandbox}"
DISP=:99
if [ "$1" = stop ]; then pkill -TERM -f '^./Delta-V[.]x86_64' || true; exit 0; fi
N="${1:-2}"
SAVES="${2:-$HOME/.var/app/com.valvesoftware.Steam/.local/share/dV}"
STEAM_GAME="${DV_GAME:-$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/dV Rings of Saturn}"

mkdir -p "$SB/game/mods" "$SB/logs"
for f in Delta-V.x86_64 Delta-V.pck libsteam_api.so; do ln -f "$STEAM_GAME/$f" "$SB/game/$f"; done

if [ ! -S /tmp/.X11-unix/X99 ]; then
  setsid Xvnc $DISP -geometry 1600x900 -depth 24 -SecurityTypes None -rfbport -1 \
    -rfbunixpath "$SB/vnc.sock" -rfbunixmode 0600 -nolisten tcp -localhost > "$SB/logs/xvnc.log" 2>&1 < /dev/null &
  for i in $(seq 1 15); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 1; done
fi

DV_GAME="$SB/game" python3 -I tools/build.py

for k in $(seq 1 "$N"); do
  rm -rf "$SB/home/$k" "$SB/data/$k"
  mkdir -p "$SB/home/$k" "$SB/data/$k/dV"
  cp "$SAVES"/*.dv "$SAVES"/settings.cfg "$SB/data/$k/dV/" 2>/dev/null || true
  if [ "$k" = 1 ]; then net=(--coop-enet-host=7777); else net=(--coop-enet-join=127.0.0.1:7777 --coop-dive-offset=0,$(( (k-1)*5000 ))); fi
  ( cd "$SB/game" && HOME="$SB/home/$k" XDG_DATA_HOME="$SB/data/$k" DISPLAY=$DISP \
      setsid ./Delta-V.x86_64 --enable-mods "${net[@]}" --coop-autodive > "$SB/logs/$k.out" 2>&1 < /dev/null & )
  sleep 6
done
echo "launched $N on $DISP. logs: $SB/data/<k>/dV/logs/dv_log_*.txt (COOP lines), stdout in $SB/logs/<k>.out"
echo "screenshot: ffmpeg -loglevel error -y -f x11grab -video_size 1600x900 -i $DISP -frames:v 1 shot.png"
