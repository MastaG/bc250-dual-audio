# Architecture

How the two outputs share one piece of hardware without colliding.

For the audio-format background this design rests on — IEC61937, carrier rates,
the non-audio bit — see [AUDIO-BACKGROUND.md](AUDIO-BACKGROUND.md).

## The core constraint

The BC-250 exposes **one** playback PCM for DisplayPort audio: `hw:Generic,3`
(also reachable as `hdmi:CARD=Generic,DEV=0` — same device, different ALSA name).

Two things want it:

- the stock PipeWire ACP sink (native LPCM)
- the ALSA `a52` plugin (AC-3)

ALSA gives it to exactly one of them. A second opener gets `EBUSY`. When that
happens mid-switch the consequences are ugly: the native node enters ERROR,
vanishes from the tray, gets destroyed and recreated, and audio dies until
something re-probes.

So output selection is treated as a **global mode**, not a per-stream target:

```text
native | ac3
```

Every application stream — and every KDE/pavucontrol sink-monitor capture
stream, which is a real source of accidental wake-ups — is forced to follow the
one selected mode.

## Components

```text
┌─ 90-bc250-audio-mode.lua ──────────── the arbiter (WirePlumber script)
│    owns mode selection, backend lifecycle, the hardware lock
│
├─ monitors/alsa.lua ────────────────── patched stock ALSA monitor
│    keeps native HDMI visible-but-suspended while an encoder owns the PCM
│
├─ 60-bc250-ac3-output.conf ─────────── the virtual sink (null-sink)
├─ 61-bc250-a52.conf ────────────────── the AC-3 encoder PCM
└─ 50-bc250-audio.conf ──────────────── policy settings the arbiter reads
```

The encoded output is a **null-sink**: permanently present, always visible, and
it never touches hardware itself. A hidden backend is attached while it is
selected, and only then does anything open the PCM. That's why the sink doesn't
disappear when you switch away from it.

It runs with `node.always-process = true`, so it keeps producing encoded silence
between application sounds. Receivers otherwise drop their Dolby lock in the gaps
and clip the start of the next sound.

## The AC-3 path

```text
application 5.1 PCM
  → bc250_ac3              null-sink, visible in the UI
  → hidden A52 backend          created only while AC-3 is selected
  → ALSA a52 plugin             encodes to AC-3 5.1 @ 640 kbps
  → hdmi:CARD=Generic,DEV=0     with IEC61937 channel status
```

Encoding happens inside ALSA, in-process. There is no helper daemon, which is
why AC-3 was always the more robust of the two paths — and, in the end, why it
is the only one left.

The slave device carries explicit channel status
(`AES0=0x06,AES1=0x82,AES2=0x00,AES3=0x02`). `AES0=0x06` sets the non-audio bit,
which tells the receiver to decode rather than play the bitstream as PCM;
`AES3=0x02` declares 48 kHz. This matters because **`hw:` device names cannot
carry AES parameters at all** — that's why the slave is the `hdmi:` name for the
same device. Before v0.12 the slave was a bare `hw:Generic,3` and the stream went
out flagged as ordinary PCM at a declared 44.1 kHz.

`plug:bc250_a52_noaes` is the same encoder with no channel status, kept
selectable for receivers that turn out to prefer the old behaviour.

## Why there is no E-AC-3 path any more

Up to v0.13 a second output encoded Dolby Digital Plus through an external
process: a `pipe-tunnel` backend wrote PCM into a FIFO, an always-resident user
service read it, and `ffmpeg -c:a eac3 | aplay -c 2 -r 192000` framed it as
IEC61937 onto the same PCM.

FFmpeg has no ALSA-plugin equivalent, so E-AC-3 needed an external process, and
that process was the source of every hard problem this project had: it was not
under WirePlumber's control, yet it held the hardware. Working around that took
an explicit two-way handshake over `bc250.eac3.*` keys in PipeWire's `default`
metadata — permit granted late, withdrawn early, release acknowledged rather
than assumed — plus `setsid` process groups and a persistent
`pw-metadata --monitor` per session.

It worked, but the latency never did. Every buffer in the chain filled at
startup and nothing drained them again; v0.13 got it from roughly 780 ms down to
a little over 170 ms by sizing each stage explicitly, and it was still audibly
laggy. v0.14 removed the whole path — service, FIFO, helper binaries, permit
handshake and the DD+ sink — leaving AC-3 at its 640 kbps ceiling, which reaches
the same hardware in-process with none of the arbitration.

If you need the history, it is in the v0.8–v0.13 entries of
[CHANGELOG.md](../CHANGELOG.md).

## Native HDMI while an encoder owns the device

Native must stay *visible* — it disappears from the UI otherwise — while not
being allowed to open the hardware. Two mechanisms:

- `node.suspend-on-idle = true` on the native node, so it releases the PCM
  promptly when nothing is linked to it.
- The patched ALSA monitor honours an internal hardware lock
  (`bc250.audio.ac3-hardware-lock`). While set, the monitor defers native
  re-creation and re-probing instead of racing.

Hotplug and profile changes temporarily release the encoded owner, let ACP
recreate and suspend native HDMI, then reclaim the encoded mode.

## Why /usr/local/share

`monitors/alsa.lua` is a full replacement for a script the `wireplumber` package
owns. It can't be installed over the original — that would clobber a
package-owned file. It also can't simply be renamed: WirePlumber refuses to start
at all when two components both declare `provides = monitor.alsa`, failing with
`no component provides 'monitor.alsa'` rather than picking one. That was
established by testing, not assumed.

`/usr/local/share` precedes `/usr/share` in WirePlumber's search path, so a copy
there shadows the stock script *under its original name* while leaving the
packaged file untouched. It is the only mechanism available.

The consequence: **this file must be rebased whenever WirePlumber changes.**
`install.sh` verifies both the running version and the stock script's SHA256
before installing, so a distro update can't silently apply a stale patch.

`90-bc250-audio-mode.lua` has no such constraint — the name is ours, nothing
collides — so when packaged it goes to the normal `/usr/share` script directory.

## Reading a switch in the logs

A healthy AC-3 → native handover, in order:

```text
wireplumber: unloading ac3 bridge
wireplumber: AC3 backend graph gone; starting 1000 ms hardware guard after release acknowledgement
wireplumber: encoded hardware lock -> false
wireplumber: native mode READY
```

Follow it live:

```bash
journalctl --user -u wireplumber -f | \
  grep --line-buffered -E 'BC-250|AC3|encoded|reprobe'
```
