#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo "Run this as the desktop/Steam user, NOT with sudo. The script calls sudo itself." >&2
  exit 1
fi

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$HOME/.local/state/bc250-audio-backup/$STAMP"
mkdir -p "$BACKUP/user" "$BACKUP/system"

echo "BC-250 Dual Audio v0.14 installer"
echo "Native HDMI/DP + AC3 640 kbps"
echo "Backup: $BACKUP"

# ---------------------------------------------------------------------------
# Version / dependency gates
# ---------------------------------------------------------------------------
WP_VERSION=$(wireplumber --version 2>/dev/null | grep -Eo '0\.5\.[0-9]+' | head -1 || true)
EXPECTED_WP_VERSION="0.5.17"
EXPECTED_STOCK_ALSA_SHA256="b0f15addcd2b36a8a5cd87555b9cbd822de1b8663545e5add2faf3d2f4c50211"
STOCK_ALSA="/usr/share/wireplumber/scripts/monitors/alsa.lua"

if [[ "$WP_VERSION" != "$EXPECTED_WP_VERSION" && "${BC250_ALLOW_UNTESTED_WP:-0}" != "1" ]]; then
  echo "ERROR: this package is rebased and tested for WirePlumber $EXPECTED_WP_VERSION." >&2
  echo "Detected: ${WP_VERSION:-unknown}" >&2
  echo "Set BC250_ALLOW_UNTESTED_WP=1 only if you intentionally want to test another version." >&2
  exit 2
fi

if [[ -f "$STOCK_ALSA" && "${BC250_ALLOW_UNTESTED_WP:-0}" != "1" ]]; then
  STOCK_ALSA_SHA256=$(sha256sum "$STOCK_ALSA" | awk '{print $1}')
  if [[ "$STOCK_ALSA_SHA256" != "$EXPECTED_STOCK_ALSA_SHA256" ]]; then
    echo "ERROR: distro stock alsa.lua does not match the WirePlumber 0.5.17 base used by v0.14." >&2
    echo "Expected: $EXPECTED_STOCK_ALSA_SHA256" >&2
    echo "Found:    $STOCK_ALSA_SHA256" >&2
    echo "Refusing to install a full monitor shadow override onto an unknown base." >&2
    echo "Set BC250_ALLOW_UNTESTED_WP=1 only for deliberate testing." >&2
    exit 3
  fi
fi

for cmd in pactl wpctl pw-metadata sha256sum grep tr awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 4
  fi
done

# Remember whether v0.7's old AC3 node was the configured default so we can
# migrate it to the new SteamOS-friendly node.name after PipeWire restarts.
OLD_CONFIGURED_SINK=$(pw-metadata -n default 0 2>/dev/null | \
  sed -n 's/.*default\.configured\.audio\.sink.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
  head -1 || true)
# v0.13 dropped the bitrate from the sink names, because the bitrates became
# configurable and a name like bc250_ac3_448 stops being true the moment you
# change one. v0.14 removes E-AC-3 outright, so anyone whose saved default was
# an E-AC-3 sink is moved to AC-3 rather than left pointing at a sink that no
# longer exists. Either way a stale saved default would silently stop resolving.
MIGRATE_TO_SINK=""
case "$OLD_CONFIGURED_SINK" in
  bc250_ac3_448)  MIGRATE_TO_SINK=bc250_ac3 ;;
  bc250_eac3_768) MIGRATE_TO_SINK=bc250_ac3 ;;
  bc250_eac3)     MIGRATE_TO_SINK=bc250_ac3 ;;
esac
if [[ -n "$MIGRATE_TO_SINK" ]]; then
  echo "Will migrate configured default $OLD_CONFIGURED_SINK -> $MIGRATE_TO_SINK"
fi

backup_user_file() {
  local path=$1
  local tag=$2
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a "$path" "$BACKUP/user/$tag"
  else
    : > "$BACKUP/user/$tag.missing"
  fi
}

backup_system_file() {
  local path=$1
  local tag=$2
  if sudo test -e "$path"; then
    sudo cp -a "$path" "$BACKUP/system/$tag"
    sudo chown "$USER":"$(id -gn)" "$BACKUP/system/$tag"
  else
    : > "$BACKUP/system/$tag.missing"
  fi
}

# Back up both old prototype files and all host-wide files replaced by v0.13.
backup_user_file "$HOME/.config/wireplumber/wireplumber.conf.d/50-bc250-ac3.conf" "user-50-bc250-ac3.conf"
backup_user_file "$HOME/.local/share/wireplumber/scripts/monitors/alsa.lua" "user-alsa.lua"
backup_user_file "$HOME/.config/pipewire/pipewire.conf.d/ac3-sink.conf" "user-ac3-sink.conf"

backup_system_file "/etc/alsa-card-profile/mixer/profile-sets/hdmi-ac3.conf" "system-hdmi-ac3.conf"
backup_system_file "/etc/alsa/conf.d/61-bc250-a52.conf" "system-61-bc250-a52.conf"
backup_system_file "/etc/pipewire/pipewire.conf.d/60-bc250-ac3-output.conf" "system-60-bc250-ac3-output.conf"
backup_system_file "/etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf" "system-50-bc250-audio.conf"
backup_system_file "/usr/local/share/wireplumber/scripts/90-bc250-audio-mode.lua" "system-90-bc250-audio-mode.lua"
backup_system_file "/usr/local/share/wireplumber/scripts/monitors/alsa.lua" "system-alsa.lua"
# Still backed up, not still installed: these are what a v0.13 system has, and
# rollback.sh restores them if someone goes back.
backup_system_file "/usr/local/libexec/bc250-eac3-backend" "system-bc250-eac3-backend"
backup_system_file "/usr/local/libexec/bc250-pipe-size" "system-bc250-pipe-size"
backup_system_file "/etc/systemd/user/bc250-eac3-backend.service" "system-bc250-eac3-backend.service"

echo "$BACKUP" > "$HOME/.local/state/bc250-audio-last-backup"

# Remove higher-priority user overrides from the early prototype.
rm -f "$HOME/.config/wireplumber/wireplumber.conf.d/50-bc250-ac3.conf"
rm -f "$HOME/.config/pipewire/pipewire.conf.d/ac3-sink.conf"
rm -f "$HOME/.local/share/wireplumber/scripts/monitors/alsa.lua"

# The profile-based AC3 mapping is no longer used; native ACP is explicitly
# forced to default.conf by 50-bc250-audio.conf.
sudo rm -f /etc/alsa-card-profile/mixer/profile-sets/hdmi-ac3.conf

sudo install -d -m 0755 /etc/alsa/conf.d
sudo install -d -m 0755 /etc/pipewire/pipewire.conf.d
sudo install -d -m 0755 /etc/wireplumber/wireplumber.conf.d
sudo install -d -m 0755 /usr/local/share/wireplumber/scripts/monitors
sudo install -d -m 0755 /usr/local/libexec
sudo install -d -m 0755 /etc/systemd/user

sudo install -m 0644 "$ROOT_DIR/etc/alsa/conf.d/61-bc250-a52.conf" \
  /etc/alsa/conf.d/61-bc250-a52.conf
sudo install -m 0644 "$ROOT_DIR/etc/pipewire/pipewire.conf.d/60-bc250-ac3-output.conf" \
  /etc/pipewire/pipewire.conf.d/60-bc250-ac3-output.conf
sudo install -m 0644 "$ROOT_DIR/etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf" \
  /etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf
sudo install -m 0644 "$ROOT_DIR/usr/local/share/wireplumber/scripts/90-bc250-audio-mode.lua" \
  /usr/local/share/wireplumber/scripts/90-bc250-audio-mode.lua
sudo install -m 0644 "$ROOT_DIR/usr/local/share/wireplumber/scripts/monitors/alsa.lua" \
  /usr/local/share/wireplumber/scripts/monitors/alsa.lua
# v0.14 removed E-AC-3. Anyone coming from v0.13 has a resident helper service
# holding a FIFO, and leaving it enabled would keep a unit running with nothing
# to feed it -- and keep a claimant for hw:Generic,3 around. Retire it here
# rather than expecting people to know it existed.
systemctl --user disable --now bc250-eac3-backend.service 2>/dev/null || true
sudo rm -f /etc/systemd/user/bc250-eac3-backend.service \
  /usr/local/libexec/bc250-eac3-backend \
  /usr/local/libexec/bc250-pipe-size
rm -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bc250-eac3.pcm"
systemctl --user daemon-reload

echo
echo "Installed. Restarting the user audio stack..."
systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 4

if [[ -n "$MIGRATE_TO_SINK" ]]; then
  # wpctl needs a PipeWire node ID; a pactl sink index is a different namespace
  # and is not safe to pass to wpctl. Parse the actual ID from wpctl status.
  # Anchor on an exact name match rather than a substring.
  NEW_SINK_ID=$(wpctl status -n 2>/dev/null | awk -v want="$MIGRATE_TO_SINK" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == want) {
          for (j = 1; j < i; j++) {
            if ($j ~ /^[0-9]+\.$/) { gsub(/\./, "", $j); print $j; exit }
          }
        }
      }
    }')
  if [[ -n "${NEW_SINK_ID:-}" ]]; then
    wpctl set-default "$NEW_SINK_ID"
    echo "Migrated configured default to $MIGRATE_TO_SINK (PipeWire node $NEW_SINK_ID)"
    sleep 2
  else
    echo "WARNING: could not find the PipeWire node ID for $MIGRATE_TO_SINK; old default was not migrated." >&2
  fi
fi

echo
echo "=== WirePlumber ==="
systemctl --user --no-pager --full status wireplumber | sed -n '1,14p' || true

echo
echo "=== sinks ==="
pactl list sinks short || true

echo
echo "=== defaults ==="
pw-metadata -n default 0 2>/dev/null | grep -E 'default\.(configured\.)?audio\.sink' || true

echo
echo "=== recent BC-250 policy log ==="
journalctl --user -u wireplumber --since "1 minute ago" --no-pager | \
  grep -E 'BC-250|s-bc250-audio|A52|AC3|encoded|Failed|error|Error' || true

echo
echo "Done. Reboot once before the real Steam/KDE regression test."
echo "Rollback with: $ROOT_DIR/rollback.sh"
