# Stargoose Cracktro — Atari STE Port

A 68000-assembly recreation of RATBOY's 1988 Bladerunners / S.T.C.S. Stargoose cracktro,
ported from Shazz's 2011 HTML5/CODEF JavaScript version (`js_version/main.html`).

Target: **Atari STE, 50 Hz PAL, low-res 320×200×16**. Tools: VASM + Hatari.

## Build & run

```bash
uv run tools/build.py --run       # assemble + launch in Hatari
uv run tools/build.py             # assemble only
uv run tools/build.py --assets    # regenerate build/*.bin from assets/
uv run tools/build.py --clean     # wipe build/
```

## Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — layers, data flow, memory budget
- [`decisions.md`](decisions.md) — ADRs for the non-obvious choices
- [`PLAN.md`](PLAN.md) — phased plan, P0 through P10

## Credits

- **Original (1988):** RATBOY / S.T.C.S. — the Bladerunners cracktro used for Stargoose, R-Type, and others
- **HTML5/CODEF port (2011):** Shazz — [wab.com/screen.php?screen=6](https://wab.com/screen.php?screen=6)
- **STE port (2026):** Matt + Anima
