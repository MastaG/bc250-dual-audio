# BC-250 Dual Audio v0.11

Realtime Dolby Digital / Dolby Digital Plus output modes for the AMD BC-250 on
CachyOS, while keeping the normal HDMI/DisplayPort output completely native and
EDID/ELD-driven.

Target: **CachyOS / PipeWire 1.6.x / WirePlumber 0.5.17 / AMD BC-250**.

## v0.11

v0.11 keeps the v0.10 permit/session ownership handshake, but fixes the long
8-9 second E-AC-3 teardown observed during real switching tests. v0.10 was
safe -- it kept the encoded hardware lock until the helper had really released
HDMI -- but the helper only noticed teardown when the PipeWire FIFO disappeared
or reached EOF. On this stack that could take several seconds.

v0.11 makes **permit withdrawal event-driven** with one persistent
`pw-metadata --monitor` client for each active EAC3 session:

```text
WirePlumber                    bc250-eac3-backend
-----------                    ------------------
FIFO/bridge synced
SESSION appears <------------- helper attached
     |
     +-- publish PERMIT -----> pw-metadata monitor receives update
                               ffmpeg/aplay may open HDMI

leave EAC3
     |
     +-- delete PERMIT -----> pw-metadata monitor receives remove
                               TERM complete ffmpeg/aplay process group
                               wait until aplay is gone
                               clear HARDWARE
                               clear SESSION
     |
     +-- wait SESSION gone <-- release acknowledgement
     |
     +-- 1000 ms guard
     |
     +-- native / AC3 / next EAC3 owner may start
```

The metadata monitor is not repeatedly spawned or polled. One line-buffered
`pw-metadata -m -n default 0 bc250.eac3.permit` process stays attached while an
EAC3 session is active. The helper blocks on its event stream with a short read
timeout only so it can also detect an unexpected encoder exit or FIFO removal.

The handshake still uses these namespaced keys in PipeWire's `default` metadata
object:

```text
bc250.eac3.permit    WirePlumber commit / immediate stop signal
bc250.eac3.session   helper attached; release acknowledgement
bc250.eac3.hardware  diagnostic: ffmpeg/aplay may own HDMI
```

Important v0.11 changes:

- `bc250.eac3.permit` deletion is now the **primary teardown signal**.
- The helper terminates the complete `setsid` process group immediately after
  the metadata remove event, instead of waiting for FIFO EOF/unlink.
- FIFO disappearance remains as a secondary fail-safe.
- If the metadata monitor itself exits unexpectedly while EAC3 owns HDMI, the
  helper fails safe and terminates the encoder pipeline.
- A fresh permit query immediately before launch is retained to close the small
  commit/start race; there is no repeated `pw-metadata` process polling while
  EAC3 is running.
- `bc250.eac3.session` is still cleared only after `aplay` has been reaped, so
  WirePlumber never releases the global hardware lock based on a timer alone.
- v0.10's process-group teardown, release acknowledgement and complete-frame PCM
  relay remain intact.
- v0.9's FIFO re-create/retry fix remains intact.

Expected practical switching time after EAC3 permit withdrawal is now roughly
the encoder termination time plus the existing 1000 ms hardware guard, instead
of the previous 8-9 second FIFO/EOF delay.

## Visible outputs

```text
normal ACP HDMI/DisplayPort sink
bc250_ac3_448
bc250_eac3_768
```

Descriptions:

```text
Dolby Digital 5.1 (AC3 448 kbps)
Dolby Digital Plus 5.1 (E-AC3 768 kbps)
```

The native HDMI/DP sink stays fully ACP/ELD/EDID-driven; the project does not
hard-code its PCM channel count.

## Audio paths

```text
Native:
application PCM
  -> stock ACP HDMI/DP sink
  -> channel layout from ELD/EDID

AC-3:
application 5.1 PCM
  -> bc250_ac3_448
  -> hidden ALSA a52 backend
  -> AC-3 5.1 @ 448 kbps
  -> hw:Generic,3

E-AC-3:
application 5.1 PCM
  -> bc250_eac3_768
  -> hidden PipeWire FIFO backend
  -> bc250-eac3-backend.service
  -> FFmpeg eac3 @ 768 kbps
  -> IEC61937 E-AC-3 framing
  -> 2ch S16_LE / 192 kHz HDMI carrier
  -> hdmi:CARD=Generic,DEV=0,AES0=0x06
```

FFmpeg's native E-AC-3 encoder is used as 5.1 only. This project does not claim
7.1 E-AC-3 or Atmos/JOC encoding.

## ELD behaviour

By default the external EAC3 helper only opens HDMI when the connected ELD
advertises E-AC-3 / Dolby Digital Plus. An unsupported monitor can therefore
show `bc250_eac3_768` but will receive silence rather than a forced compressed
bitstream.

For a deliberate transport test on a monitor whose ELD does not advertise DD+:

```bash
systemctl --user edit bc250-eac3-backend.service
```

Add:

```ini
[Service]
Environment=BC250_EAC3_IGNORE_ELD=1
```

Then:

```bash
systemctl --user daemon-reload
systemctl --user restart bc250-eac3-backend.service
```

## Global mutual exclusion

The BC-250 exposes one physical DisplayPort audio PCM. Output selection in
SteamOS/KDE is therefore treated as a global mode:

```text
native | ac3 | eac3
```

Normal application streams and KDE/pavucontrol sink-monitor streams follow the
same global target. Per-application native/AC3/EAC3 splits are intentionally
prevented.

AC3 continues to use the proven ALSA A52 path. EAC3 uses the permit/session
handshake described above. The v0.7-derived ALSA-monitor guard keeps native HDMI
visible but suspended while either encoded mode owns/reserves the physical PCM.

## Keepalive

Both encoded frontends stay processing while selected so downstream receivers
can keep their Dolby lock between application sounds. Native HDMI remains
suspendable because it must release the hardware before an encoded mode starts.

## Files

```text
/etc/alsa/conf.d/61-bc250-a52.conf
/etc/pipewire/pipewire.conf.d/60-bc250-ac3-output.conf
/etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf
/etc/systemd/user/bc250-eac3-backend.service
/usr/local/libexec/bc250-eac3-backend
/usr/local/share/wireplumber/scripts/90-bc250-audio-mode.lua
/usr/local/share/wireplumber/scripts/monitors/alsa.lua
```

The custom `monitors/alsa.lua` remains a downstream patch rebased on stock
WirePlumber **0.5.17**. The installer verifies the WirePlumber version and the
known stock script SHA256 before installing the `/usr/local` shadow override;
it does not overwrite `/usr/share/wireplumber/...`.

## Dependencies

The installer checks for:

- WirePlumber 0.5.17 (unless deliberately overridden)
- PipeWire `libpipewire-module-pipe-tunnel`
- ALSA `aplay`
- FFmpeg with `eac3` encoder and `spdif`/IEC61937 muxer
- util-linux `setsid`

## Install / upgrade

Run as the normal Steam/Desktop user, not with sudo:

```bash
./install.sh
```

The installer calls sudo for system-wide custom files, enables/restarts the EAC3
user service, restarts PipeWire/WirePlumber and stores a rollback snapshot.
Reboot once before the final Steam Gaming Mode regression test.

## Basic test

```bash
./check.sh
```

Then repeatedly test:

```text
native -> EAC3 -> native
AC3 -> EAC3 -> AC3
EAC3 -> AC3 -> EAC3
```

For an EAC3 -> native handover, the intended log order is now:

```text
EAC3 hardware permit withdrawn
unloading eac3 bridge
...
bc250-eac3-backend: EAC3 hardware permit withdrawal event received
bc250-eac3-backend: stopping E-AC-3 pipeline (EAC3 hardware permit withdrawn)
bc250-eac3-backend: hardware release acknowledged
...
EAC3 helper release acknowledged
1000 ms hardware guard after release acknowledgement
encoded hardware lock -> false
native mode READY
```

This check should remain empty:

```bash
journalctl --user -u pipewire --since "10 minutes ago" --no-pager | \
  grep -Ei 'busy|EBUSY|playback open failed|Start error'
```

Follow the two cooperating sides live with:

```bash
journalctl --user -u wireplumber -f | \
  grep --line-buffered -E 'BC-250|AC3|EAC3|permit|SESSION|acknowledged|reprobe'
```

and:

```bash
journalctl --user -u bc250-eac3-backend -f
```

## Rollback

```bash
./rollback.sh
```
