# Changelog

All notable changes to BC-250 Dual Audio. Newest first.

Versions before v0.8 predate this file; v0.5-v0.7 built the native/AC-3
arbitration, the configured-default authority, the hardware lock and reprobe
logic, and the KDE monitor-stream guard that the current design still rests on.

## v0.13

Cuts E-AC-3 latency and drops the bitrate from the sink names.

**E-AC-3 was carrying roughly 780 ms of buffering.** Latency through that path
is the sum of every buffer in the chain, because they all fill during startup
and nothing drains them again. Measured on hardware, `aplay` alone held a
501 ms ALSA buffer -- its 500 ms default, which the pipeline never overrode --
and each of the three kernel pipes contributed a further 57-85 ms at their
default 64 KiB.

- `aplay` now runs with an explicit `--buffer-time` (64 ms) and `--period-time`
  (16 ms), tunable via `BC250_EAC3_BUFFER_TIME_US` / `BC250_EAC3_PERIOD_TIME_US`.
  Raise the buffer first if the sink stutters.
- New `bc250-pipe-size` helper sets `F_SETPIPE_SZ` on the pipes and execs the
  real command; the shell cannot make that call itself. Wrapping FFmpeg sizes
  both pipes around it, and the FIFO is sized from the reader end. Default
  16 KiB, tunable via `BC250_EAC3_PIPE_BYTES`. This adds a `python` dependency.
- FFmpeg gains `-fflags nobuffer -flags low_delay -probesize 32
  -analyzeduration 0`, which mainly removes startup probing.
- Together these take the chain to roughly 200 ms. The remaining floor is the
  32 ms encoder frame, the 32 ms prebuffer that detects a cancelled transition,
  and PipeWire's own graph latency.

AC-3 is unchanged: it encodes inside PipeWire via the ALSA `a52` plugin, so it
was already near its floor of the quantum plus one 32 ms AC-3 frame.

**Sinks renamed** `bc250_ac3_448` -> `bc250_ac3` and `bc250_eac3_768` ->
`bc250_eac3`. The bitrates became configurable in v0.12, so a name asserting one
stops being true as soon as it is changed; the descriptions lost their bitrates
for the same reason. `install.sh` migrates a saved configured default across,
but a per-application output pinned to an old name has to be picked again.

## v0.12

v0.12 changes two things: it stops checking sink capabilities entirely, and it
fixes the IEC61937 channel status on the AC-3 path.

- **No capability checks anywhere.** The ELD gate on the E-AC-3 helper is
  removed along with `BC250_EAC3_IGNORE_ELD`. Adapters lie about ELD, so the
  selected mode is now always pushed to the hardware.
- **AC-3 now sets the non-audio bit.** The A52 slave moved from a bare
  `hw:Generic,3` to `hdmi:CARD=Generic,DEV=0` with explicit channel status
  (`AES0=0x06`, `AES3=0x02`). Measured on hardware, AC-3 previously advertised
  `Data: audio, Rate: 44100 Hz` while sending a 48 kHz Dolby bitstream; it now
  correctly advertises `Data: non-audio, Rate: 48000 Hz`. `hw:` cannot carry AES
  parameters at all, which is why they were missing.
  Most receivers auto-detect the AC-3 sync word and decoded it anyway, but
  strict sinks -- notably TVs forwarding audio to a receiver over ARC -- do
  honour the bit. `plug:bc250_a52_noaes` keeps the old behaviour available.
- **Both AES value and E-AC-3 bitrate are now knobs** rather than literals, so a
  receiver that dislikes either can be tested without editing code.
- **`aplay -q` dropped**, so the "rate is not accurate" warning that indicates a
  sink cannot carry the 192 kHz E-AC-3 carrier is no longer swallowed.
- **`check.sh` reports the live IEC61937 channel status**, which is the fastest
  way to confirm what a receiver is actually being told.

The v0.10 ownership handshake and v0.11 event-driven permit withdrawal are
unchanged.

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

## v0.10

Fixed the E-AC-3 teardown race found in real switching tests on v0.9. The FIFO
lifecycle fix held, but `ffmpeg | aplay` could stay alive for several seconds
after WirePlumber had destroyed the E-AC-3 graph, so native HDMI reopened
`hw:Generic,3` too early and hit `EBUSY`.

- Replaced the timer-only release assumption with an explicit two-way ownership
  handshake over namespaced keys in PipeWire's `default` metadata object:
  `bc250.eac3.permit`, `bc250.eac3.session`, `bc250.eac3.hardware`.
- The permit is granted only after the FIFO backend and bridge are loaded,
  PipeWire has synced and the requested generation is still current; it is
  withdrawn *before* the graph is torn down.
- The helper runs the PCM feeder, FFmpeg and `aplay` in a dedicated process
  group (`setsid`) and tears the group down as one unit. `SESSION` is cleared
  only once the group is reaped, which is what proves `aplay` closed the device.
- `KillMode=control-group` on the unit, so stopping the service reaps the whole
  pipeline rather than just the wrapper.
- The PCM relay feeds FFmpeg whole 1536-sample frames, padding only a final
  short block, fixing `Invalid PCM packet` from a trailing partial sample.

## v0.9

Reliability fix for the E-AC-3 backend introduced in v0.8.

- PipeWire may unlink `/run/user/$UID/bc250-eac3-768.pcm` when its dynamic
  `pipe-tunnel` module unloads, which happens on every E-AC-3 mode transition.
  The backend created the FIFO once at startup and assumed the pathname
  persisted, so after switching away it spun on ENOENT / `Bad file descriptor`.
- The FIFO is now re-validated and re-created before every backend cycle, with
  bounded retries on open failure.
- `check.sh` gained a FIFO lifecycle error section.

## v0.8

Added a second encoded output alongside AC-3.

- New output `bc250_eac3_768`: Dolby Digital Plus 5.1 at 768 kbps, for chains
  that accept DD+ but not multichannel LPCM.
- New always-resident `bc250-eac3-backend` user service. It blocks on a FIFO and
  only opens HDMI when WirePlumber creates the pipe-tunnel backend, encoding
  with FFmpeg and framing as IEC61937 over the HDMI PCM.
- Output selection became a three-way global mode: `native | ac3 | eac3`.
- Renamed `bc250_ac3` to `bc250_ac3_448` for a clearer SteamOS output selector.
  The underlying `bc250_a52` ALSA path was unchanged, so v0.7 installs upgraded
  without reconfiguring AC-3.
- New dependencies: `ffmpeg` and `alsa-utils`.

## v0.7

- Rebased the `monitors/alsa.lua` override onto stock WirePlumber **0.5.17**.
  `install.sh` verifies the stock monitor's SHA256 first, so a distro update
  cannot silently apply the BC-250 patch on top of an unknown base.
- Fixed a KDE race: Plasma and pavucontrol create sink-monitor capture streams
  for their peak meters, and such a stream could remain on the suspended native
  HDMI sink and wake it while A52 owned the hardware, producing `EBUSY`. The
  global `select-target` policy now covers sink-monitor capture streams too.
  Real microphone capture is untouched.
