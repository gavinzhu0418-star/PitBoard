# PitBoard

A tiny macOS menu bar app for Formula 1 race weekends.

Click the menu bar icon to see:

- the current or next Grand Prix (round x of y), every session in your local time, and a countdown
- the official circuit map for that round — hover over it and it smoothly enlarges to cover the whole panel
- constructor standings in team colours; the leader's points turn gold once the title is mathematically decided
- the top 10 drivers by points, in team colours; P1–P3 turn gold, silver and bronze once those places are decided
- the top 10 of the latest finished session with each driver's best lap: practice ordered by lap time,
  qualifying, sprint and race by classification; the session's fastest lap in purple

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

- Schedule and standings: [Jolpica F1 API](https://github.com/jolpica/jolpica-f1), the community successor to the Ergast API.
- Latest session results and team colours: [OpenF1](https://openf1.org). Its free tier serves a session from about 30 minutes after it ends.
- Circuit maps: loaded at runtime from formula1.com and cached in `~/Library/Caches/PitBoard`. No images are included in this repository.

PitBoard is an unofficial fan project and is not affiliated with Formula 1, the FIA or any team. F1, FORMULA 1 and related marks are trademarks of Formula One Licensing B.V.

## License

MIT — see [LICENSE](LICENSE). The license covers this project's code only.
