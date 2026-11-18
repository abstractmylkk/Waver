# Waver

A minimal open-source macOS loudness + waveform meter.

## Build

```bash
./build.sh             # -> build/Waver.app + build/Waver.component
./build.sh --install   # app -> /Applications, AU -> ~/Library/Audio/Plug-Ins/Components
```

## Audio Unit Plug-in

`Waver.component` is an AUv2 effect by mylkAudio (or just abstractmylkk). It passes audio through
untouched and meters it.

- **Reset on Play** (on by default) clears integrated loudness, LRA and peaks whenever Live's transport starts,
  so each playthrough is measured on its own.
- Target, time window, scale and Reset-on-Play are saved with the Live Set.
- Check the install with `auval -v aufx Wavr Mylk`.

Requires macOS 14.4+ and Xcode command-line tools (for building). `swift run -c release WaverSelfTest` checks the meter against EBU reference signals.

## Sources

- **System Audio** - everything the Mac plays (Core Audio process tap; no BlackHole/Loopback needed).
- **Applications** - a single app, e.g. *Ableton Live* (listed while it has audio running).
- **Input Devices** - audio interfaces or loopback drivers.

The first time you meter system/app audio, macOS asks for permission to capture audio. If you declined, enable Waver under
System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only).

## Readings

| | |
|---|---|
| Momentary / Short-term / Integrated | EBU R128 / ITU-R BS.1770-4 (400 ms / 3 s / gated) |
| LRA | Loudness range, EBU Tech 3342 |
| True Peak | 4× oversampled, max since reset (dBTP) |
| PSR | True peak (last 3 s) − short-term loudness. Under ~8 LU = heavily limited |
| PLR | Max true peak − integrated loudness |

Waveform colours show where the energy is: red = lows, yellow = mids, blue = highs. `⌘R` resets statistics,
`⌘P` pauses, `⌘L` switches the waveform to a dB scale. The pin button keeps the window above other apps.



Built with the help of Claude Code.
