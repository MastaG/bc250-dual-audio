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

This is why an encoded stream is written as 16-bit stereo: those aren't audio
parameters, they're the shape of the container.

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

## Carrier rates

Different codecs need different amounts of room in the IEC61937 container. This
project only ships AC-3 — the first row — but the second explains why:

| Codec | Carrier | Available bandwidth | Codec ceiling |
|---|---|---|---|
| AC-3 (Dolby Digital) | 48 kHz, 2 ch, 16-bit | 1.536 Mbit/s | 640 kbit/s |
| E-AC-3 (Dolby Digital Plus) | **192 kHz**, 2 ch, 16-bit | 6.144 Mbit/s | ~6 Mbit/s |

E-AC-3 frames carry more data, so IEC 61937 transports them at **4× the sample
rate**. This is not optional and not a quality setting — it is how DD+ is framed.

The practical consequence: **a link that cannot do 192 kHz cannot carry DD+ at
all**, regardless of software configuration. A stereo-only display whose ELD caps
the PCM at 48 kHz could never work in E-AC-3 mode. AC-3 has no such problem: its
48 kHz carrier is what every one of these links already does.

## Checking what a link actually supports

```bash
aplay -D hw:CARD=Generic,DEV=3 --dump-hw-params /dev/zero 2>&1 | grep -E '^RATE|^CHANNELS'
```

A stereo-only monitor reports something like `RATE: [32000 48000]`, which is all
AC-3 needs. A chain that also offers 192000 could have carried DD+.

## How to tell "broken" from "incompatible"

A sink that cannot decode AC-3 typically plays the bitstream as **loud static**
— it treats the compressed data as PCM. Before v0.12, which is when the
non-audio bit started being set, that was the normal failure for any
incompatible sink. With the bit set correctly, a sink that recognises
"compressed, can't decode" may instead simply **mute**.

So **noise is not proof that a mode is working**, and **silence is not proof
that it's broken**. Check what is actually being sent rather than guessing from
the sound:

```bash
iecset -c 0 | grep -E 'Data|Rate'
```

`Data: non-audio` means the receiver is being told to decode it as Dolby, which
is correct. `Data: audio` means it will be played as PCM — noise.

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

## Bitrate

**AC-3 @ 640 kbit/s** is the default and also the codec's ceiling — the top of
its frame-size table. The encode is software and the DisplayPort link carries it
comfortably, so there is nothing to save by going lower. 448 was the default
before v0.14 and remains a valid setting if some receiver prefers it.

### Why E-AC-3 was dropped

v0.13 and earlier also offered Dolby Digital Plus. Its one real advantage was
the bitrate ceiling: AC-3 stops at 640 kbit/s and E-AC-3 does not. That mattered
less than it sounds, because FFmpeg's E-AC-3 encoder is essentially **the AC-3
encoder emitting E-AC-3 syntax** — it implements none of E-AC-3's efficiency
tools such as spectral extension, so quality per bit is close to AC-3 rather
than meaningfully better. It is 5.1 maximum, with no Atmos or JOC.

Against that, DD+ needed an external FFmpeg process behind a FIFO, a 192 kHz
carrier that many links could not carry, and a permit handshake to stop it
racing PipeWire for the one PCM. The latency it added was audible and never got
below roughly 170 ms. Trading that for at most a marginal quality gain over
640 kbit/s AC-3 was not worth it, so v0.14 removed the path.

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
