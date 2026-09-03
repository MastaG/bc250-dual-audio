# BC-250 dual-output audio prototype v0.6

## v0.6 configured-default authority

v0.6 changes only the **mode-selection authority** on top of the working v0.5
hardware arbitration / keepalive implementation. The BC-250 policy now watches
PipeWire's `default.configured.audio.sink` metadata (the persistent user choice
written by Steam, KDE and `wpctl set-default`) and treats that as authoritative
whenever it exists. `default.audio.sink` / `default-nodes-api` is used only as
the automatic fallback when no configured default exists (for example after
`wpctl clear-default`).

This prevents a hot-unplug of the native HDMI/DP sink from being misread as a
user selecting `bc250_ac3` merely because the permanent AC3 frontend is the only
remaining effective sink. A configured native choice therefore stays native
through unplug/replug; a configured AC3 choice stays AC3 and still uses the v0.5
release/reprobe/reclaim maintenance cycle.

The v0.5 ALSA monitor guard, AC3 hardware lock, hotplug reprobe and AC3
keepalive settings are otherwise unchanged. The AC3 frontend also remains
`node.virtual=true` in v0.6, so KDE may require **Show Virtual Devices** to be
enabled in its audio UI; this revision intentionally does not change that UI
classification.

## v0.5 fix

v0.5 adds hotplug-safe mutual exclusion between the native HDMI ACP node and
the hidden A52 backend. The patched ALSA monitor now consults an internal
WirePlumber runtime hardware lock before opening native HDMI. If HDMI/DP is
replugged while AC3 owns `hw:Generic,3`, it holds the native node pending and
asks the arbiter for a maintenance reprobe instead of opening the PCM and
hitting `EBUSY`. The arbiter temporarily releases A52, lets native ACP
enumerate and suspend, then reclaims the hardware for AC3.

v0.5 also keeps the AC3 pipeline processing silence while AC3 mode is active,
so receivers / soundbars / TVs do not lose Dolby Digital lock between sounds.

## v0.2 fix

This version fixes daemon-side default-output tracking. WirePlumber daemon scripts cannot use `Core.require_api()`; v0.2 attaches to the already-loaded `default-nodes-api` with `Plugin.find()` and retries until the plugin is available.


Target: **CachyOS / WirePlumber 0.5.16 / BC-250**.

## What this builds

Two permanent user-facing outputs:

1. **Native HDMI / DisplayPort** — the normal ACP sink. Its channel count and
   channel map are not hard-coded; they remain driven by the connected sink's
   ELD/EDID (PCM 2.0, LPCM 5.1/7.1, etc.).
2. **Dolby Digital 5.1 (AC3 Encoder)** — a permanent six-channel PipeWire
   virtual sink.

The AC3 frontend is a null sink. It does not touch ALSA hardware. When it is
selected as the configured system default, WirePlumber moves normal application streams
onto that frontend, waits until native HDMI is SUSPENDED, waits a 1000 ms
hardware guard, creates a hidden A52 ALSA backend (`plug:bc250_a52` ->
`hw:Generic,3`) and bridges the virtual sink monitor into it.

When native HDMI is selected again, the bridge is unloaded, the hidden A52
backend is destroyed, PipeWire is synchronized, the 1000 ms guard runs, and
only then are normal application streams allowed back onto native HDMI.

## Mode authority

The policy distinguishes the two default-node concepts that WirePlumber exposes:

- `default.configured.audio.sink`: persistent user selection; authoritative.
- `default.audio.sink`: current effective selection; only used when there is no
  configured default.

You can inspect both with:

```bash
pw-metadata -n default 0
```

This distinction is what keeps an HDMI hotplug from silently changing the global
BC-250 mode.

## Mutual exclusion

The custom `select-target` hook runs before WirePlumber's stock
`linking/find-defined-target` hook. For normal `Stream/Output/Audio` clients it
forces the current global BC-250 target. This intentionally prevents a state
such as:

- Firefox -> AC3
- Spotify -> native HDMI

A per-application move in pavucontrol/KDE should therefore be rejected/snapped
back to the selected global mode. Switch the system output with Steam/KDE's
normal output selector instead.

Internal bridge streams are marked `bc250.internal=true` and bypass the rule.

## Files

- `/etc/alsa/conf.d/61-bc250-a52.conf`
- `/etc/pipewire/pipewire.conf.d/60-bc250-ac3-output.conf`
- `/etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf`
- `/usr/local/share/wireplumber/scripts/90-bc250-audio-mode.lua`
- `/usr/local/share/wireplumber/scripts/monitors/alsa.lua`

The `monitors/alsa.lua` file is the exact BC-250 guard version that already
passed the profile-switch torture test in this machine. It is deliberately
pinned to WirePlumber 0.5.16.

## Install

Run as the normal Steam/Desktop user (not `sudo`):

```bash
./install.sh
```

The installer uses `sudo` for host-wide files, backs up the current working
profile-based prototype, removes its higher-priority user overrides and then
restarts PipeWire/WirePlumber.

**Reboot once after installation** before judging Steam Gaming Mode behaviour.

## First tests

After reboot:

```bash
./check.sh
wpctl status -n
```

You should see the native HDMI/DP sink plus:

```text
Dolby Digital 5.1 (AC3 Encoder)
```

On the Acer XB273K, selecting AC3 should produce the expected digital
`trrrrrrr` because the monitor only accepts PCM. On a decoder/TV path that
accepts AC3, it should decode as Dolby Digital 5.1.

Follow policy logs while switching:

```bash
journalctl --user -u wireplumber -f | grep --line-buffered -E 'BC-250|A52|AC3|s-bc250-audio'
```

Expected native -> AC3 sequence:

```text
effective target -> bc250_ac3
native HDMI is suspended; starting 1000 ms hardware guard
creating hidden A52 backend on plug:bc250_a52
AC3 mode READY: virtual frontend -> A52 backend -> hw:Generic,3
```

Expected AC3 -> native sequence:

```text
unloading AC3 bridge
A52 backend gone; starting 1000 ms hardware guard
effective target -> alsa_output....hdmi-...
native mode READY
```

No `EBUSY` should appear.

## Test status / v0.6 focus

On this BC-250, v0.5 has already passed native <-> AC3 switching from both
SteamOS and KDE without `EBUSY`, and the hotplug lock/reprobe handshake has
successfully released A52 and allowed the native HDMI node to reopen without a
hardware-busy error.

v0.6 intentionally changes only the authority used to decide the desired mode.
The first v0.6 regression test should therefore verify that a configured native
selection stays native across unplug/replug (no temporary AC3 mode), followed by
a configured AC3 unplug/replug test where AC3 remains the desired mode and the
v0.5 reprobe/reclaim cycle completes. Keep the v0.5 backup until those tests pass.

## Rollback

```bash
./rollback.sh
```

This restores the files backed up by the most recent `install.sh` run.

## v0.4 transition fix

v0.4 fixed a race found on a real BC-250 boot: if the effective default changed
from the temporary AC3 frontend to native HDMI while the 1000 ms AC3 guard was
still pending, v0.3 cancelled the transition timer but left the transition marked
busy. Normal streams could then remain pinned to the silent AC3 null frontend.

v0.4 lets an in-flight transition unwind via its generation check instead of
cancelling its owning timer, and makes startup settling quiescence-based: the
settle window restarts on relevant default-node / BC-250 sink changes.


## v0.5 hotplug + AC3 keepalive

- Adds an internal WirePlumber runtime hardware lock between the AC3 arbiter and
  the patched ALSA monitor. If DP/HDMI is replugged while AC3 owns `hw:Generic,3`,
  the native node is held pending instead of racing A52 and producing EBUSY.
- The arbiter performs a maintenance cycle: unload A52, guard, allow native ACP
  to enumerate and suspend, guard again, then reopen A52. The selected AC3 mode
  and application routing stay unchanged during this reprobe.
- The AC3 frontend and hidden backend are configured to remain processing while
  idle (`node.always-process=true`, suspend disabled, timeout 0) so receivers,
  TVs and soundbars can retain their Dolby Digital lock between application
  sounds.
