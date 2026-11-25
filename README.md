# PitBoard

A tiny macOS menu bar app for Formula 1 race weekends.

Click the menu bar icon to see:

- the current or next Grand Prix (round x of y), every session in your local time, and a countdown
- the official circuit map for that round — hover over it and it smoothly enlarges to cover the whole panel

It sits idle in the menu bar (no timers, no polling) and only goes online when you open it and the data is more than 10 minutes old.

## Build

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
bash build.sh
open PitBoard.app
```

To check the data without the UI:

```bash
./PitBoard.app/Contents/MacOS/PitBoard --print
```

### Menu bar icon

Put your own `MenuIcon.png` (13 px tall) and `MenuIcon@2x.png` (26 px tall) next to `build.sh` before building. Without them the menu bar shows 🏁.

## Data

- Schedule: [Jolpica F1 API](https://github.com/jolpica/jolpica-f1), the community successor to the Ergast API.
- Circuit maps: loaded at runtime from each race page on formula1.com and cached in `~/Library/Caches/PitBoard`. No images are included in this repository.

PitBoard is an unofficial fan project and is not affiliated with Formula 1, the FIA or any team. F1, FORMULA 1 and related marks are trademarks of Formula One Licensing B.V.

## License

MIT — see [LICENSE](LICENSE). The license covers this project's code only.
