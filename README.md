# PitBoard

A tiny macOS menu bar app for Formula 1 race weekends.

Click the menu bar icon to see:

- the current or next Grand Prix (round x of y), every session in your local time, and a countdown
- the official circuit map for that round — hover over it and it smoothly enlarges to cover the whole panel
- constructor standings in team colours; the leader's points turn gold once the title is mathematically decided
- under them, for that round: Pirelli's three compounds (hard white, medium yellow, soft red, plus any per-set lap
  limit), how the top three ran the last race on this circuit (stints coloured by compound, pit laps), and the
  circuit's length, laps and lap record (holder in the colour of the team he set it with)
- all drivers by points, in team colours; P1–P3 turn gold, silver and bronze once those places are decided
- the full results of the latest finished session: practice by best lap, qualifying by classification with best laps
  (fastest in purple); sprint and race like the official classification — the winner's time, then the gap
  (+s, +laps, DNF) — with the fastest lap holder on an extra line, lap time in purple
- under it, the forecast for the next race: start › an hour in › the finish, as three weather icons

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
- Circuit maps, circuit facts and tyre compounds: read at runtime from formula1.com (the race page and Pirelli's
  "What tyres will…" article, found via the race page or the news feed) and cached in `~/Library/Caches/PitBoard`.
  No images are included in this repository.
- Last race on this circuit: OpenF1 race results and tyre stints (2023 onwards); lap record holder's team: Jolpica.
- Race weather: [Open-Meteo](https://open-meteo.com) (data CC BY 4.0), at the circuit's coordinates from Jolpica,
  from about 15 days before the race.

PitBoard is an unofficial fan project and is not affiliated with Formula 1, the FIA or any team. F1, FORMULA 1 and related marks are trademarks of Formula One Licensing B.V.

## License

MIT — see [LICENSE](LICENSE). The license covers this project's code only.
