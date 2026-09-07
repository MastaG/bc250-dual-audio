# Architecture

How the three outputs share one piece of hardware without colliding.

For the audio-format background this design rests on — IEC61937, carrier rates,
the non-audio bit — see [AUDIO-BACKGROUND.md](AUDIO-BACKGROUND.md).

## The core constraint

The BC-250 exposes **one** playback PCM for DisplayPort audio: `hw:Generic,3`
(also reachable as `hdmi:CARD=Generic,DEV=0` — same device, different ALSA name).

Three things want it:

- the stock PipeWire ACP sink (native LPCM)
- the ALSA `a52` plugin (AC-3)
- `ffmpeg | aplay` inside the E-AC-3 helper

ALSA gives it to exactly one of them. A second opener gets `EBUSY`. When that
happens mid-switch the consequences are ugly: the native node enters ERROR,
vanishes from the tray, gets destroyed and recreated, and audio dies until
something re-probes.

So output selection is treated as a **global mode**, not a per-stream target:

```text
native | ac3 | eac3
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
├─ 60-bc250-ac3-output.conf ─────────── the two virtual sinks (null-sinks)
├─ 61-bc250-a52.conf ────────────────── the AC-3 encoder PCM
├─ 50-bc250-audio.conf ──────────────── policy settings the arbiter reads
│
└─ bc250-eac3-backend(.service) ─────── the E-AC-3 encoder, a separate process
```

The two encoded outputs are **null-sinks**: permanently present, always visible,
and they never touch hardware themselves. A hidden backend is attached to
whichever one is selected, and only then does anything open the PCM. That's why
the sinks don't disappear when you switch away from them.

Both encoded sinks run with `node.always-process = true`, so they keep producing
encoded silence between application sounds. Receivers otherwise drop their Dolby
lock in the gaps and clip the start of the next sound.

## The AC-3 path

```text
application 5.1 PCM
  → bc250_ac3              null-sink, visible in the UI
  → hidden A52 backend          created only while AC-3 is selected
  → ALSA a52 plugin             encodes to AC-3 5.1 @ 448 kbps
  → hdmi:CARD=Generic,DEV=0     with IEC61937 channel status
```

Encoding happens inside ALSA, in-process. There is no helper daemon, which is
why AC-3 has always been the more robust of the two paths.

The slave device carries explicit channel status
(`AES0=0x06,AES1=0x82,AES2=0x00,AES3=0x02`). `AES0=0x06` sets the non-audio bit,
which tells the receiver to decode rather than play the bitstream as PCM;
`AES3=0x02` declares 48 kHz. This matters because **`hw:` device names cannot
carry AES parameters at all** — that's why the slave is the `hdmi:` name for the
same device. Before v0.12 the slave was a bare `hw:Generic,3` and the stream went
out flagged as ordinary PCM at a declared 44.1 kHz.

`plug:bc250_a52_noaes` is the same encoder with no channel status, kept
selectable for receivers that turn out to prefer the old behaviour.

## The E-AC-3 path

```text
application 5.1 PCM
  → bc250_eac3                       null-sink, visible in the UI
  → hidden pipe-tunnel backend           writes PCM into a FIFO
  → $XDG_RUNTIME_DIR/bc250-eac3.pcm
  → bc250-eac3-backend.service           separate always-resident process
  → ffmpeg -c:a eac3 -b:a 768k
  → IEC61937 framing (-f spdif)
  → aplay -c 2 -r 192000                 the 4× carrier DD+ requires
  → hdmi:CARD=Generic,DEV=0,AES0=0x06
```

FFmpeg has no ALSA-plugin equivalent, so E-AC-3 needs an external process. That
process is the source of every hard problem this project has had: it is not
under WirePlumber's control, yet it holds the hardware.

The helper is **always running** but blocks on the FIFO. It owns nothing until
WirePlumber creates the pipe-tunnel backend and grants permission.

## The ownership handshake

Because the encoder is an independent process, WirePlumber cannot know when it
has truly released the device. Guessing produced two distinct bugs: releasing too
early gave `EBUSY`, waiting on indirect signals gave 8–9 second switches.

The current design is an explicit two-way handshake over namespaced keys in
PipeWire's `default` metadata object:

| Key | Written by | Meaning |
|---|---|---|
| `bc250.eac3.permit` | WirePlumber | the transition is committed; you may open HDMI |
| `bc250.eac3.session` | helper | attached; still holding, or acknowledging release |
| `bc250.eac3.hardware` | helper | diagnostic: `ffmpeg`/`aplay` may own the device |

```text
WirePlumber                          bc250-eac3-backend
───────────                          ──────────────────
FIFO + bridge loaded, graph synced
SESSION appears           ←───────── helper attached
  │
  ├─ publish PERMIT       ─────────→ metadata monitor sees "update"
  │                                  ffmpeg/aplay open HDMI

user leaves E-AC-3
  │
  ├─ delete PERMIT        ─────────→ metadata monitor sees "remove"
  │                                  TERM the whole process group
  │                                  wait until aplay is reaped
  │                                  clear HARDWARE, then SESSION
  │
  ├─ wait for SESSION gone ←──────── release acknowledgement
  ├─ 1000 ms hardware guard
  └─ native / AC-3 / next owner may start
```

Three properties make this work:

**The permit is granted late.** Only after the bridge is loaded, PipeWire has
synced, *and* the requested generation is still current. A transition cancelled
midway can therefore never cause a late hardware open.

**The permit is withdrawn early** — before the graph is torn down, not after.

**Release is acknowledged, not assumed.** `SESSION` is cleared only once the
entire process group has been reaped, which is what actually proves `aplay`
closed the ALSA device. WirePlumber waits for that. If it takes unusually long
it logs a warning after 3 s and *keeps waiting* rather than letting another
backend race the hardware — fail-safe, not fail-fast.

The helper watches for withdrawal with one persistent `pw-metadata --monitor`
process per session, attached via `coproc`, so teardown is event-driven. FIFO
disappearance is retained as a secondary signal.

The pipeline runs under `setsid` in its own process group, and the unit sets
`KillMode=control-group`, so the feeder, FFmpeg and `aplay` are always stopped as
one unit. Killing only the wrapper would leave `aplay` holding the device.

## Native HDMI while an encoder owns the device

Native must stay *visible* — it disappears from the UI otherwise — while not
being allowed to open the hardware. Two mechanisms:

- `node.suspend-on-idle = true` on the native node, so it releases the PCM
  promptly when nothing is linked to it.
- The patched ALSA monitor honours an internal hardware lock
  (`bc250.audio.ac3-hardware-lock`, named before E-AC-3 existed; it now means
  *either* encoder owns or reserves the device). While set, the monitor defers
  native re-creation and re-probing instead of racing.

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

A healthy E-AC-3 → native handover, in order:

```text
wireplumber: EAC3 hardware permit withdrawn (EAC3 bridge teardown)
wireplumber: unloading eac3 bridge
backend:     EAC3 hardware permit withdrawal event received
backend:     stopping E-AC-3 pipeline (EAC3 hardware permit withdrawn)
backend:     hardware release acknowledged
wireplumber: EAC3 helper release acknowledged (mode handover)
wireplumber: starting 1000 ms hardware guard after release acknowledgement
wireplumber: encoded hardware lock -> false
wireplumber: native mode READY
```

Follow both sides live:

```bash
journalctl --user -u wireplumber -f | \
  grep --line-buffered -E 'BC-250|AC3|EAC3|permit|SESSION|acknowledged|reprobe'

journalctl --user -u bc250-eac3-backend -f
```
