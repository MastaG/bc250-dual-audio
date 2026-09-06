# Audio background

The domain knowledge this project depends on. Most of the non-obvious bugs here
were misunderstandings of one of these points, so it's worth reading before
changing anything in the encoded paths.

## Compressed audio travels in a PCM-shaped pipe

HDMI and S/PDIF were designed to carry plain PCM samples. Dolby Digital is not
PCM — so it gets smuggled through, wrapped in a format called **IEC 61937**. The
compressed bitstream is chopped into "data bursts" and stuffed into what looks,
electrically, like an ordinary stereo PCM stream.

Everything downstream — the GPU, the cable, an adapter, the TV's input stage —
handles it as if it were stereo PCM. Only the final decoder knows better.

This is why `aplay` writes an E-AC-3 stream with `-f S16_LE -c 2`: those aren't
audio parameters, they're the shape of the container.

## The non-audio bit

Alongside the samples, IEC 60958 carries a small metadata block called **channel
status**. One bit in it — the *non-audio* bit, bit 1 of byte 0 — means:

> These are not audio samples. Do not play them. Decode them.

| Bit | Receiver behaviour |
|---|---|
| Set | Switches its Dolby decoder on, typically lights up "Dolby Digital", outputs 5.1 |
| Clear | Assumes PCM, sends the compressed bytes straight to the speakers → **loud static** |

That static is the classic symptom of a bitstream reaching a device that was
never told what it is.

In ALSA the byte is set through the device name:

```text
hdmi:CARD=Generic,DEV=0,AES0=0x06,AES1=0x82,AES2=0x00,AES3=0x02
```

- `AES0=0x06` — consumer mode, non-audio bit **set**
- `AES3=0x02` — declares 48 kHz

**`hw:` device names cannot carry AES parameters at all.** If you find yourself
wanting to set channel status on a `hw:` device, you need the `hdmi:` name for
the same card instead. This project's AC-3 path shipped with a bare
`hw:Generic,3` slave until v0.12 and consequently advertised `Data: audio` with a
declared rate of 44100 while sending a 48 kHz Dolby bitstream.

Read the live state with:

```bash
iecset -c 0 | grep -E 'Data|Rate'
```

**Why the wrong flag went unnoticed for so long:** most receivers don't trust the
bit. They scan the incoming stream for the AC-3 sync word (`0x0B77`) and
auto-switch when they see it. Strict sinks do honour it — notably TVs forwarding
audio to a receiver over ARC, since the TV has to decide what to forward.

## Carrier rates: why E-AC-3 needs 192 kHz

Different codecs need different amounts of room in the IEC61937 container:

| Codec | Carrier | Available bandwidth | Codec ceiling |
|---|---|---|---|
| AC-3 (Dolby Digital) | 48 kHz, 2 ch, 16-bit | 1.536 Mbit/s | 640 kbit/s |
| E-AC-3 (Dolby Digital Plus) | **192 kHz**, 2 ch, 16-bit | 6.144 Mbit/s | ~6 Mbit/s |

E-AC-3 frames carry more data, so IEC 61937 transports them at **4× the sample
rate**. This is not optional and not a quality setting — it is how DD+ is framed.

The practical consequence: **a link that cannot do 192 kHz cannot carry DD+ at
all**, regardless of software configuration. A stereo-only display whose ELD caps
the PCM at 48 kHz will never work in E-AC-3 mode.

## The `aplay` rate trap

This one is genuinely dangerous, because it fails *successfully*.

Ask for a rate the hardware can't do and `aplay` does not error out:

```text
$ aplay -D hdmi:CARD=Generic,DEV=0,AES0=0x06 -t raw -f S16_LE -c 2 -r 192000 ...
Playing raw data 'stdin' : Signed 16 bit Little Endian, Rate 192000 Hz, Stereo
Warning: rate is not accurate (requested = 192000Hz, got = 48000Hz)
$ echo $?
0
```

It warns, runs at whatever the device allows, and exits 0. The pipeline looks
completely healthy — `ffmpeg` keeps encoding, `aplay` keeps consuming, the
process stays alive for hours — while the E-AC-3 bursts go out at a quarter of
the rate they need. No receiver can decode that.

`aplay -q` suppresses the warning, so a quiet pipeline hides the only evidence.
That's why this project no longer uses `-q`.

Check what a link actually supports:

```bash
aplay -D hw:CARD=Generic,DEV=3 --dump-hw-params /dev/zero 2>&1 | grep -E '^RATE|^CHANNELS'
```

A stereo-only monitor reports something like `RATE: [32000 48000]`. A DD+-capable
chain will offer 192000.

## How to tell "broken" from "incompatible"

The two encoded modes fail differently, which is confusing until you know why:

| | Sink can't decode it | Why |
|---|---|---|
| **AC-3** | Loud static | Historically shipped without the non-audio bit, so the sink played it as PCM |
| **E-AC-3** | Silence | Correctly flagged non-audio, so the sink recognises "compressed, can't decode" and mutes |

So **noise is not proof that a mode is working**, and **silence is not proof that
it's broken**. Use the logs, not your ears:

```bash
journalctl --user -u bc250-eac3-backend | grep -i 'rate is not accurate'
```

Present → the link can't carry DD+. Absent, with the pipeline running → the
stream is going out correctly and the sink simply can't decode it.

## ELD, and why this project ignores it

**ELD** (EDID-Like Data) is what the kernel extracts from the display's EDID and
exposes at `/proc/asound/card*/eld#*`. It lists Short Audio Descriptors: which
codecs, channel counts and rates the sink claims to support.

```bash
cat /proc/asound/card0/eld#0.0
```

A stereo monitor looks like this:

```text
speakers          [0x1] FL/FR
sad_count         1
sad0_coding_type  [0x1] LPCM
sad0_channels     2
sad0_rates        [0xe0] 32000 44100 48000
```

In principle you could gate encoded modes on it. In practice, **don't**:

- **Active and passive DP→HDMI adapters synthesise their own ELD.** What you read
  often describes the adapter's assumptions, not the device behind it.
- An AVR in the middle may present its own capabilities rather than the TV's, or
  vice versa, depending on how the chain negotiates.
- Some sinks under-report formats they handle perfectly well.

This project therefore performs **no capability checks**. The selected mode is
always pushed to the hardware, and an incompatible sink is left to reject it. A
sink refusing audibly is more diagnosable than a helper refusing on the strength
of metadata that may be fiction.

ELD is still useful as *evidence* when troubleshooting — just not as a gate.

## FFmpeg's E-AC-3 encoder

Worth knowing what you're actually getting:

- It is essentially **the AC-3 encoder emitting E-AC-3 syntax.** It does not
  implement E-AC-3's efficiency tools such as spectral extension, so quality per
  bit is close to AC-3 rather than meaningfully better.
- **5.1 maximum.** No 7.1. This is why the project doesn't advertise it.
- **No Atmos / JOC**, which would require joint object coding.

The real advantage of the E-AC-3 path is therefore not efficiency — it's the
**bitrate ceiling**. AC-3 stops at 640 kbit/s; E-AC-3 does not.

### Bitrate choices

- **AC-3 @ 448 kbit/s** — the long-standing default. 640 is available if you want
  AC-3's maximum.
- **E-AC-3 @ 768 kbit/s** — above anything AC-3 can reach, and a common rate in
  streaming DD+ content, so receivers are well exercised at it.

Setting E-AC-3 to 640 would give you roughly max-bitrate AC-3 with extra decode
complexity and no benefit — it discards the only advantage the path has. If you
want to experiment, experiment *upward* (1024k, 1536k) on a direct HDMI run;
there is ample room in a 6.144 Mbit/s carrier. ARC paths are less predictable at
high rates.

## Useful commands

```bash
# what the sink claims to support
cat /proc/asound/card0/eld#0.0

# what the link actually allows
aplay -D hw:CARD=Generic,DEV=3 --dump-hw-params /dev/zero 2>&1 | grep -E '^RATE|^CHANNELS'

# what the receiver is being told right now
iecset -c 0 | grep -E 'Data|Rate'

# who currently owns the device, and at what parameters
cat /proc/asound/card0/pcm3p/sub0/status
cat /proc/asound/card0/pcm3p/sub0/hw_params
```

That last pair is the ground truth for "which mode really owns the hardware" —
more reliable than any sink state reported further up the stack.
