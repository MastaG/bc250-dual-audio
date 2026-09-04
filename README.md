# BC-250 Dual Audio v0.9

Realtime Dolby Digital / Dolby Digital Plus output modes for the AMD BC-250 on
CachyOS, while keeping the normal HDMI/DisplayPort output completely native and
EDID/ELD-driven.

Target: **CachyOS / PipeWire 1.6.x / WirePlumber 0.5.17 / AMD BC-250**.

## v0.9

v0.9 is a focused reliability update for the E-AC-3 backend introduced in
v0.8. It keeps the same native / AC-3 / E-AC-3 architecture and fixes the
FIFO lifecycle observed during real mode switching.

Changes:

- Re-validates and re-creates `/run/user/$UID/bc250-eac3-768.pcm` before every
  E-AC-3 backend cycle. PipeWire may unlink this FIFO when its dynamic
  `pipe-tunnel` module is unloaded.
- Handles FIFO open/create failures as transient lifecycle races with a bounded
  retry instead of continuing with an invalid file descriptor.
- Prevents the previous ENOENT / `Bad file descriptor` tight loop and the
  resulting unnecessary CPU usage after E-AC-3 -> AC-3/native transitions.
- Keeps the v0.8 codec names and bitrates unchanged:
  `bc250_ac3_448` and `bc250_eac3_768`.
- WirePlumber 0.5.17 remains the tested/rebased target.

## v0.8

v0.8 keeps the proven v0.7 native/AC3 arbitration and adds a second encoded
output for **Dolby Digital Plus 5.1 (E-AC-3) at 768 kbps**.

The visible encoded sinks are now named explicitly for SteamOS:

```text
bc250_ac3_448
bc250_eac3_768
```

Their UI descriptions are:

```text
Dolby Digital 5.1 (AC3 448 kbps)
Dolby Digital Plus 5.1 (E-AC3 768 kbps)
```

The original HDMI/DP output remains a normal WirePlumber ACP sink. Nothing in
this project hard-codes its PCM layout: the connected display/receiver's ELD
still decides whether native PCM is stereo, 5.1, 7.1, etc.

## Why the two encoded modes?

Use **native HDMI/DP PCM** when the complete path supports multichannel LPCM.
That is lossless and remains the preferred mode.

**AC-3 5.1 @ 448 kbps** is the compatibility mode for TVs, AVRs, soundbars,
HDMI extractors and S/PDIF/TOSLINK-style paths that cannot transport
multichannel LPCM but do accept classic Dolby Digital.

**E-AC-3 / Dolby Digital Plus 5.1 @ 768 kbps** is intended for newer chains
that support DD+, including many TVs that can pass DD+ to an AVR/soundbar over
regular HDMI ARC. Support is device-dependent; eARC is not required for DD+,
but not every ordinary ARC implementation accepts/passes an externally supplied
DD+ stream.

FFmpeg's native E-AC-3 encoder currently supports up to 5.1 for this use case;
v0.8 therefore does **not** advertise 7.1 or Atmos/JOC.

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

For 48 kHz E-AC-3, Linux's HDMI ELD constraints map the compressed-format SAD
to the IEC61937 transport parameters (2 channels at 192 kHz). The helper only
opens this path when the connected ELD advertises E-AC-3/DD+. If it does not,
the EAC3 frontend remains selectable but its PCM is consumed silently instead
of repeatedly attempting an unsupported hardware open.

For deliberate testing against hardware with incorrect/missing ELD reporting,
the ELD check may be overridden with a user-service drop-in:

```bash
systemctl --user edit bc250-eac3-backend.service
```

Add:

```ini
[Service]
Environment=BC250_EAC3_IGNORE_ELD=1
```

Then run:

```bash
systemctl --user daemon-reload
systemctl --user restart bc250-eac3-backend.service
```

## Global mutual exclusion

The BC-250 has one physical DisplayPort audio path. Native PCM, AC-3 and E-AC-3
therefore cannot own the HDMI PCM simultaneously.

The WirePlumber policy treats output selection as a global mode:

```text
native | ac3 | eac3
```

Normal application playback and KDE/pavucontrol sink-monitor streams are forced
to that one selected mode. Per-application splits such as Firefox -> EAC3 while
Spotify -> native HDMI are intentionally prevented.

Transitions are serialized:

```text
old backend/links stop
  -> PipeWire sync
  -> hardware release guard
  -> new backend starts
```

The same v0.7 ALSA-monitor guard remains responsible for keeping the native HDMI
node visible but safely suspended while an encoded backend owns the physical
PCM. Hotplug/reprobe temporarily releases the encoded owner, lets ACP recreate
and suspend native HDMI, then reclaims the selected encoded mode.

## Keepalive

Both encoded frontends stay processing while selected. AC3's A52 backend and
EAC3's FIFO/FFmpeg path therefore continue carrying encoded silence between
application sounds, avoiding repeated Dolby lock/unlock cycles on TVs,
soundbars and receivers.

Native HDMI deliberately does **not** use this keepalive because it must be able
to release the PCM promptly before switching to an encoded mode.

## E-AC-3 backend service

`bc250-eac3-backend.service` is a system-wide user unit. It is enabled for the
Steam/Desktop user and normally consumes essentially no work: it blocks waiting
for a FIFO writer.

WirePlumber only creates that writer while `bc250_eac3_768` is selected. When
the writer appears, the helper requires one complete 1536-sample E-AC-3 frame
before opening HDMI, then starts FFmpeg + aplay. A cancelled/partial transition
never opens the hardware. When WirePlumber unloads the FIFO backend, EOF tears
down the pipeline and releases HDMI before the normal 1000 ms hardware guard
expires.

Helper logs:

```bash
journalctl --user -u bc250-eac3-backend -f
```

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
WirePlumber **0.5.17**. The installer checks both the WirePlumber version and
the known stock script SHA256 before installing the shadow override. No package
file under `/usr/share` is overwritten.

## Dependencies

The installer verifies:

- WirePlumber 0.5.17 (unless intentionally overridden)
- PipeWire's `libpipewire-module-pipe-tunnel`
- ALSA `aplay`
- FFmpeg with the native `eac3` encoder
- FFmpeg's `spdif` / IEC61937 muxer

## Install / upgrade

Run as the normal Steam/Desktop user, **not** with sudo:

```bash
./install.sh
```

The installer calls sudo for `/etc` and `/usr/local`, enables the EAC3 user
service, restarts the audio stack and creates a rollback snapshot.

If upgrading from v0.7 while the old `bc250_ac3` sink is the configured default,
the installer automatically migrates that preference to `bc250_ac3_448`.

Reboot once after installation before judging Steam Gaming Mode behaviour.

## Basic check

```bash
./check.sh
```

Expected visible sinks:

```text
bc250_ac3_448
bc250_eac3_768
alsa_output.pci-0000_01_00.1.hdmi-...
```

Check for the hardware race that this project is designed to avoid:

```bash
journalctl --user -u pipewire --since "10 minutes ago" --no-pager | \
  grep -Ei 'busy|EBUSY|playback open failed|Start error'
```

Expected: no output.

Follow the policy live:

```bash
journalctl --user -u wireplumber -f | \
  grep --line-buffered -E 'BC-250|A52|AC3|EAC3|encoded|reprobe|s-bc250-audio'
```

For EAC3 also follow:

```bash
journalctl --user -u bc250-eac3-backend -f
```

If the current display does not advertise DD+, selecting `bc250_eac3_768` will
not intentionally send a compressed bitstream to it. Test actual DD+ output on
a TV/AVR/soundbar chain whose ELD advertises E-AC-3/DD+.

## Rollback

```bash
./rollback.sh
```

The rollback stops/disables the EAC3 helper, restores the files backed up by the
most recent installer run and restarts PipeWire/WirePlumber.
