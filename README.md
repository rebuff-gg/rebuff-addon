# Rebuffed

The in‑game addon for **[Rebuff.gg](https://rebuff.gg)** — *figure out forever WoW with data.*

Rebuffed guarantees your gameplay is recorded so it can be turned into answers on the web:

- **Always‑on combat logging.** Forces Advanced Combat Logging on the moment you log in — everywhere, not just in instances — and complains loudly (and keeps re‑enabling it) if anything turns it off. There is no off switch; recording is the whole point.
- **A fight/leveling landmark index.** Records the things the combat‑log file can't carry — session/encounter/challenge‑mode/zone boundaries, per‑pull attempt counts, roster snapshots, level‑ups and deaths — so the uploader can line everything up exactly.
- **Cross‑client.** One code path runs on retail (the *WoW Forever* / Midnight model) **and** Classic / Season of Discovery, feature‑detecting anything that only exists on one flavor.

## Install

The **Rebuff desktop app** installs and updates this addon automatically into every WoW you have. To install manually, download the latest release and extract the `Rebuffed` folder into:

- Retail: `_retail_\Interface\AddOns\`
- Classic / SoD: `_classic_era_\Interface\AddOns\` (and `_anniversary_\Interface\AddOns\`)

Then `/reload` (or restart). Open the panel with `/rb`.

## Slash commands

`/rb` open · `/rb status` · `/rb addons` · `/rb debug` · `/rb export`

## License

MIT — see [LICENSE](LICENSE).
