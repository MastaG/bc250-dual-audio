# BC-250 Dual Audio

Real-time Dolby Digital and Dolby Digital Plus output for the AMD BC-250, while
leaving the normal HDMI/DisplayPort output completely untouched.

Tested against **CachyOS / PipeWire 1.6.x / WirePlumber 0.5.17 / AMD BC-250**.

---

## What problem does this solve?

The BC-250 outputs audio over DisplayPort. Plenty of gear on the other end of
that cable — AV receivers, soundbars, older TVs, HDMI audio extractors — cannot
accept multichannel LPCM, but *can* decode Dolby Digital. Without this project
you get stereo. With it you get real 5.1.

The catch is that the board exposes **one** physical audio device. Native PCM,
AC-3 and E-AC-3 all want to own it, and only one can at a time. Most of the code
here exists to arbitrate that safely: hand the hardware over cleanly on every
switch, and never let two backends collide (which shows up as `EBUSY`, a
disappearing sink, or silence).

## The three outputs

| Output | Shows up as | What it is | Use it when |
|---|---|---|---|
| **Native** | `alsa_output.pci-…hdmi-…` | Stock PipeWire HDMI/DP sink, untouched | Your display/receiver accepts multichannel LPCM. Lossless — always prefer this. |
| **AC-3** | `bc250_ac3` | Dolby Digital 5.1, encoded live (448 kbps default) | The chain can't take multichannel LPCM but decodes Dolby Digital. Widest compatibility. |
| **E-AC-3** | `bc250_eac3` | Dolby Digital Plus 5.1, encoded live (768 kbps default) | The chain supports DD+. Higher bitrate ceiling than AC-3 can reach. |

Selecting one is just picking the output in Steam, KDE, `pavucontrol` or
`wpctl` — no special tooling. The choice is **global**: every application
follows it. Per-app splits (Firefox on AC-3, Spotify on native) are deliberately
prevented, because they'd mean two owners of one device.

The native sink's channel count is whatever your display reports. This project
never hard-codes it.

## Install

On CachyOS with the [BC-250 repository](https://github.com/MastaG/linux-cachyos-bc250)
configured:

```bash
sudo pacman -Syu bc250-dual-audio
systemctl --user daemon-reload
systemctl --user enable --now bc250-eac3-backend.service
```

Otherwise, from a clone — run as your normal desktop user, **not** with sudo
(the script calls sudo itself):

```bash
./install.sh
```

The installer takes a rollback snapshot, installs the system-wide files, enables
the E-AC-3 helper service and restarts the audio stack. Reboot once before
judging results in Steam Gaming Mode.

### Requirements

- WirePlumber **0.5.17** — the ALSA monitor override is rebased on this exact
  version and `install.sh` refuses to install onto an unknown base
- PipeWire with `libpipewire-module-pipe-tunnel`
- FFmpeg with the `eac3` encoder and the `spdif` (IEC61937) muxer
- `alsa-plugins` (the a52 encoder), `alsa-utils` (`aplay`), `util-linux` (`setsid`)
- `python` — used only to shrink kernel pipe buffers on the E-AC-3 path

## Check that it works

```bash
/usr/share/bc250-dual-audio/check.sh     # packaged
./check.sh                               # from a clone
```

That prints the sinks, the current mode, the E-AC-3 handshake state, what your
display advertises, the live IEC61937 channel status, and any recent errors.
These three sections should all read `None.` on a healthy system:

```text
recent PipeWire hardware errors
EAC3 lifecycle / teardown errors
EAC3 release wait warnings
```

Then switch between all three outputs a few times and confirm audio follows.

## Common problems

| Symptom | Most likely cause |
|---|---|
| Loud static / screeching | The sink can't decode what you're sending. Expected on a display with no Dolby decoder. |
| E-AC-3 is silent, AC-3 isn't | Usually the sink can't carry DD+. Silence is the *correct* behaviour here — see below. |
| Audio stops after switching | Check for `EBUSY` in the PipeWire journal; that's a hardware handover failure. |
| A mode won't engage at all | Confirm `bc250-eac3-backend.service` is running (E-AC-3 only). |

**Silence in E-AC-3 mode is not automatically a bug.** A sink that can't decode
AC-3 usually plays the bitstream as noise, but a sink that can't decode a
correctly flagged E-AC-3 stream simply mutes. The fastest way to tell a dead
pipeline from an incompatible sink:

```bash
journalctl --user -u bc250-eac3-backend | grep -i 'rate is not accurate'
```

If that matches, the link cannot carry the 192 kHz carrier DD+ requires, and no
setting will change that — it's the display or the adapter in front of it.

There is much more in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

## Configuration

Defaults are deliberate and most people should not change them. When you do need
to, nothing requires editing code.

**E-AC-3** — `systemctl --user edit bc250-eac3-backend.service`:

```ini
[Service]
Environment=BC250_EAC3_BITRATE=1024k          # default 768k
Environment=BC250_ENCODED_AES0=0x04           # default 0x06 (non-audio bit set)
Environment=BC250_EAC3_BUFFER_TIME_US=96000   # ALSA buffer, default 64000 (64 ms)
Environment=BC250_EAC3_PERIOD_TIME_US=24000   # ALSA period, default 16000 (16 ms)
Environment=BC250_EAC3_PIPE_BYTES=32768       # kernel pipe size, default 16384
```

**If E-AC-3 stutters or crackles, raise `BC250_EAC3_BUFFER_TIME_US` first** (try
96000, then 128000). A small ALSA buffer is what makes the path responsive, but
the encoder pipeline is not realtime-scheduled, so too small a buffer underruns
audibly. `BC250_EAC3_PIPE_BYTES` is the second lever, and its floor is one page
(4096).

Then `systemctl --user daemon-reload && systemctl --user restart bc250-eac3-backend.service`.
The startup log line echoes the active bitrate, so you can confirm it took.

**AC-3** — bitrate lives in `/etc/alsa/conf.d/61-bc250-a52.conf`. To send without
the IEC61937 non-audio bit, point `ac3-alsa-path` at the fallback PCM in
`/etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf`:

```text
ac3-alsa-path = "plug:bc250_a52_noaes"
```

then restart WirePlumber.

> The sinks are named `bc250_ac3` and `bc250_eac3`, with no bitrate in the name,
> because the bitrates are configurable and a name like `bc250_eac3_768` stops
> being true the moment you change one. v0.13 renamed them from the older
> `bc250_ac3_448` / `bc250_eac3_768`; `install.sh` carries a saved default
> across, but if you had pinned an output per application you may need to pick
> it again.

> If you hand-edit any file under `/etc`, note they are in the package's
> `backup=` set: pacman will **preserve your version and write `.pacnew`**
> instead of applying updates. Merge them, or your edits will silently block
> future fixes.

## Latency

AC-3 encodes *inside* PipeWire through the ALSA `a52` plugin, so PipeWire's own
quantum governs it — roughly 20–40 ms plus the 32 ms AC-3 frame, which is the
codec's own frame size and cannot be removed. AC-3 is close to its floor.

E-AC-3 runs through an external process, and latency there is the **sum of every
buffer in the chain**: they all fill during startup and nothing drains them
again. Before v0.13 those defaults added up to roughly 780 ms, with `aplay`'s
default 500 ms ALSA buffer alone accounting for two thirds of it.

v0.13 sizes them explicitly:

| stage | before | after |
|---|---|---|
| FIFO (kernel pipe) | ~57 ms | ~14 ms |
| prebuffer (1 E-AC-3 frame) | 32 ms | 32 ms |
| feeder pipe into FFmpeg | ~57 ms | ~14 ms |
| E-AC-3 encoder frame | 32 ms | 32 ms |
| pipe into `aplay` | ~85 ms | ~21 ms |
| `aplay` ALSA buffer | ~500 ms | 64 ms |

The remaining floor is the 32 ms encoder frame, the 32 ms prebuffer that exists
to detect a cancelled transition, and PipeWire's own graph latency. 64 ms of
*encoding* is reachable — two frames — but 64 ms end-to-end is not without
collapsing the process chain entirely.

## No capability checks — on purpose

This project does not consult ELD/EDID before pushing a mode to the hardware. It
used to, and that was worse.

ELD is unreliable here: active and passive DP→HDMI adapters synthesise their own,
and it frequently does not describe what is actually downstream. Refusing a mode
because a lying adapter said so is more confusing than letting the sink reject it
audibly. So the selected mode is always attempted.

## Uninstall / rollback

```bash
./rollback.sh                      # restores the pre-install snapshot
sudo pacman -R bc250-dual-audio    # if installed from the repository
systemctl --user disable --now bc250-eac3-backend.service
```

Package removal does not stop the user service, and never touches the stock
WirePlumber ALSA monitor — that file is left exactly as its own package
installed it.

## Documentation

| Document | What's in it |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the arbitration works: the mode arbiter, both encoder paths, the ownership handshake, why the monitor override lives where it does |
| [docs/AUDIO-BACKGROUND.md](docs/AUDIO-BACKGROUND.md) | The domain knowledge: IEC61937, the non-audio bit, carrier rates, why ELD lies, FFmpeg's encoder limits, bitrate reasoning |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom-driven diagnosis with the commands to run and how to read the output |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

## Files installed

```text
/etc/alsa/conf.d/61-bc250-a52.conf                        AC-3 encoder PCM
/etc/pipewire/pipewire.conf.d/60-bc250-ac3-output.conf    the two virtual sinks
/etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf   policy settings
/usr/local/libexec/bc250-eac3-backend                     E-AC-3 encoder
/usr/local/libexec/bc250-pipe-size                        pipe-buffer sizer
/usr/local/share/wireplumber/scripts/monitors/alsa.lua    patched ALSA monitor
```

Two files land in different places depending on how you installed, because the
package follows distribution convention while `install.sh` is an unmanaged
install:

| File | `install.sh` | pacman package |
|---|---|---|
| helper unit | `/etc/systemd/user/` | `/usr/lib/systemd/user/` |
| mode arbiter | `/usr/local/share/wireplumber/scripts/` | `/usr/share/wireplumber/scripts/` |

If you have used both methods on one machine, check for leftovers from the other
— `/etc/systemd/user` wins over `/usr/lib/systemd/user`, so a stale unit there
will shadow the packaged one.

The patched `monitors/alsa.lua` is a downstream rebase of the stock WirePlumber
0.5.17 script. It is installed under `/usr/local/share` so it shadows the stock
copy by search-path precedence — the file owned by the `wireplumber` package is
never modified. See [ARCHITECTURE.md](docs/ARCHITECTURE.md#why-usrlocalshare)
for why it can't live anywhere else.
