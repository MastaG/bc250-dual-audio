# Troubleshooting

Symptom-driven. Start with `check.sh` — it collects almost everything below in
one pass:

```bash
/usr/share/bc250-dual-audio/check.sh     # packaged
./check.sh                               # from a clone
```

Background for the audio concepts used here is in
[AUDIO-BACKGROUND.md](AUDIO-BACKGROUND.md); the internals are in
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## First: is it broken, or is the sink incompatible?

The two encoded modes fail differently, and the difference misleads people:

- **AC-3 on a sink that can't decode it** → loud static.
- **E-AC-3 on a sink that can't decode it** → silence, because the stream is
  correctly flagged as non-audio and the sink mutes rather than playing noise.

So noise doesn't prove a mode works, and silence doesn't prove it's broken. The
decisive check:

```bash
journalctl --user -u bc250-eac3-backend | grep -i 'rate is not accurate'
```

| Result | Meaning |
|---|---|
| Matches | The link can't carry the 192 kHz carrier DD+ needs. The sink or the adapter in front of it is the limit. No software setting fixes this. |
| No match, pipeline running | The stream is going out correctly. If you hear nothing, the sink can't decode DD+. |

Confirm what the link allows:

```bash
aplay -D hw:CARD=Generic,DEV=3 --dump-hw-params /dev/zero 2>&1 | grep -E '^RATE'
```

`RATE: [32000 48000]` means DD+ is impossible on that link. A DD+-capable chain
offers 192000.

---

## E-AC-3 mode is silent

Work down this list.

**1. Is the helper running?**

```bash
systemctl --user status bc250-eac3-backend.service
```

If it isn't, E-AC-3 can never produce output — the sink will still appear and
accept audio, it just goes nowhere.

```bash
systemctl --user enable --now bc250-eac3-backend.service
```

**2. Did the handshake complete?** `check.sh` prints all three keys. With E-AC-3
selected, all three should be `PRESENT`:

```text
bc250.eac3.permit    PRESENT
bc250.eac3.session   PRESENT
bc250.eac3.hardware  PRESENT
```

| Missing key | Meaning |
|---|---|
| All absent | WirePlumber never entered E-AC-3 mode — check its journal for the mode transition |
| `session` absent | The helper never attached; check the service is running and the FIFO exists |
| `permit` absent, `session` present | WirePlumber declined to commit — usually a transition cancelled midway |
| `hardware` absent | The helper is attached but the encoder pipeline didn't start |

**3. Did the encoder actually start?**

```bash
journalctl --user -u bc250-eac3-backend --since "10 min ago" | \
  grep -E 'starting E-AC-3|permit observed|permit withdrawal'
```

**4. Is the carrier rate right?** See the section above. This is the most common
cause by a wide margin.

---

## Loud static / screeching

The sink is receiving a compressed bitstream and playing it as PCM.

**If the sink genuinely has no Dolby decoder** (a plain monitor, say) this is
expected — you're asking it to decode something it can't. Use native output.

**If the sink *should* decode it** (an AVR, a TV with Dolby support), check
whether the non-audio bit is reaching it. With the encoded mode selected and
audio playing:

```bash
iecset -c 0 | grep -E 'Data|Rate'
```

| Reading | Verdict |
|---|---|
| `Data: non-audio` / `Rate: 48000 Hz` | Correct. The sink is being told properly. |
| `Data: audio` | The receiver is being told this is PCM, so it plays noise. |

If it reads `Data: audio` for AC-3, confirm the configured path:

```bash
grep ac3-alsa-path /etc/wireplumber/wireplumber.conf.d/50-bc250-audio.conf
```

`plug:bc250_a52_noaes` is the deliberately unflagged fallback. `plug:bc250_a52`
is the flagged default. If the file was hand-edited, see the `.pacnew` trap
below — an old copy may have survived an upgrade.

---

## Audio stops after switching outputs

First establish whether it's a hardware handover failure:

```bash
journalctl --user -u pipewire --since "10 minutes ago" --no-pager | \
  grep -Ei 'busy|EBUSY|playback open failed|Start error'
```

**Empty** — the handover worked; the problem is stream routing, not the device.
Check where your stream actually landed:

```bash
pactl list sink-inputs | awk '/^Sink Input #/{id=$0} /Sink: /{print id " -> Sink: " $2}'
```

`Sink: 4294967295` means the stream is linked to nothing and will be silent.
Selecting the output again normally re-links it.

**Not empty** — two backends collided over the device. Capture the transition:

```bash
journalctl --user -u wireplumber --since "10 min ago" | \
  grep -E 'permit|SESSION|acknowledged|hardware lock|mode READY'
```

Compare against the expected sequence in
[ARCHITECTURE.md](ARCHITECTURE.md#reading-a-switch-in-the-logs). The step that's
missing tells you which side didn't release.

Ground truth for who owns the hardware, independent of anything PipeWire
reports:

```bash
cat /proc/asound/card0/pcm3p/sub0/status      # state + owner_pid
cat /proc/asound/card0/pcm3p/sub0/hw_params   # rate/format/channels
```

`owner_pid` resolves the question directly: PipeWire's own PID means native or
AC-3, an `aplay` PID means E-AC-3.

---

## Switching takes several seconds

Expect roughly 1–2 s: there's a deliberate 1000 ms hardware guard after the
encoder releases the device, which exists to prevent `EBUSY`.

Much longer than that, and the helper's release isn't being observed promptly:

```bash
journalctl --user -u wireplumber | grep 'still waiting for EAC3 helper to release HDMI'
journalctl --user -u bc250-eac3-backend | grep -E 'permit withdrawal event received|monitor exited'
```

Seeing `armed` but never `withdrawal event received` points at the metadata
monitor rather than the handshake — the helper then falls back to detecting FIFO
disappearance, which is correct but slow. Restart the service:

```bash
systemctl --user restart bc250-eac3-backend.service
```

---

## A transient link error during fast switching

```text
wp-event-dispatcher: link failed: Failed to create links because of wrong ports
```

Seen when switching faster than the graph settles, and it recovers within about
a second. It is not known to strand audio — 30+ rapid transitions, including at
0.3 s intervals, all recovered. Worth reporting if you ever see it *persist*.

---

## Native HDMI disappears from the UI

Native is meant to stay visible but suspended while an encoder owns the device.
If it vanishes entirely, it most likely entered ERROR after an `EBUSY` and was
destroyed and recreated. Follow the *audio stops after switching* steps above —
the `EBUSY` is the real fault; the disappearance is a consequence.

---

## After a distro update

Two things break specifically on updates.

**WirePlumber changed version.** The `monitors/alsa.lua` override is a full
replacement rebased on one exact stock version. Running it against a different
WirePlumber is unsupported and can misbehave subtly.

```bash
wireplumber --version
sha256sum /usr/share/wireplumber/scripts/monitors/alsa.lua
```

Compare against the values `install.sh` checks. If they've moved, the override
needs rebasing — don't just force it.

**`.pacnew` files.** The files under `/etc` are in the package's `backup=` set.
If you have ever hand-edited one, pacman **keeps your version and writes
`.pacnew`** instead of applying the update. Fixes then silently don't take
effect.

```bash
find /etc -name '*.pacnew' 2>/dev/null | grep -E 'bc250|a52'
```

Merge and delete the `.pacnew`. This is easy to miss precisely because nothing
appears to fail.

---

## Collecting a full report

For a bug report, this is the useful set:

```bash
./check.sh > /tmp/bc250-audio-report.txt 2>&1
{
  echo "=== ELD ==="; cat /proc/asound/card*/eld#* 2>/dev/null
  echo "=== link capabilities ==="
  aplay -D hw:CARD=Generic,DEV=3 --dump-hw-params /dev/zero 2>&1 | grep -E '^RATE|^CHANNELS|^FORMAT'
  echo "=== wireplumber ==="; journalctl --user -u wireplumber --since "20 min ago" --no-pager
  echo "=== backend ==="; journalctl --user -u bc250-eac3-backend --since "20 min ago" --no-pager
} >> /tmp/bc250-audio-report.txt
```

Include which mode you selected, what the chain is (direct HDMI, DP→HDMI adapter
and which kind, AVR in the middle, ARC), and what you expected to hear. The chain
matters more than almost anything else — adapters are the usual culprit.
