# Media assets for the README

Drop screenshots / GIFs here using these exact filenames so the README
references render correctly.

## Required for v0.2.0 release

| Filename                     | Type | What it shows                                               | Recommended size |
|------------------------------|------|-------------------------------------------------------------|------------------|
| `hero-autoflip.gif`          | GIF  | Hero shot: typing `руддщ` on UK, hits space → becomes `hello` and the system layout switches to ABC. Show menubar icon dimming/brightening if convenient. | 800–1000 px wide, 8–10 s, ≤ 5 MB |
| `selection-flip.gif`         | GIF  | Select a misspelled paragraph → double-tap Shift → it gets converted in place. Restore from clipboard demo too. | 800–1000 px wide, 8–10 s, ≤ 5 MB |
| `backspace-learner.gif`      | GIF  | Type a "user-jargon" word that auto-flip mistakenly fixes → press Backspace → undo + remembered. Type the same word again → no fix. | 800–1000 px wide, 6–8 s, ≤ 4 MB |
| `overlay-animation.gif`      | GIF  | Just the bouncy 180° icon flip, isolated. Useful as a "Visual confirmation" feature highlight. | 200–300 px wide, 1–2 s loop, ≤ 1 MB |
| `menubar.png`                | PNG  | Menubar dropdown showing all four items (Enabled, Auto-flip, Preferences…, Quit). | 2× retina, ≤ 800 px wide |
| `preferences-general.png`    | PNG  | Preferences > General tab.                                  | 2× retina, full window |
| `preferences-behavior.png`   | PNG  | Preferences > Behavior tab — shows the new Hotkey picker + toggles. | 2× retina, full window |
| `onboarding-step1.png`       | PNG  | First step of the onboarding wizard (Accessibility active, Input Monitoring upcoming). | 2× retina, full window |

## Recommended capture tools

- [Kap](https://getkap.co/) — free, open source, exports GIF / MP4. Perfect for the GIFs above.
- macOS built-in screenshot (⌘⇧5) for PNGs.
- Use ⌘⇧4-Space to capture a single window with shadow.

## Tips

- Record at 2× (retina) — GitHub serves them at native pixel density on hi-DPI screens.
- Keep GIFs short. 5–10 seconds is plenty; longer ones bloat the repo.
- Try to keep the cursor pointer out of frame unless it's making a point.
- For dark UI, a light background (or vice versa) makes the recording pop in README.
- If a GIF ends up > 5 MB, run it through [ezgif.com](https://ezgif.com) /
  optimize to reduce frame count.

This README file itself isn't shown anywhere in the published README — it's
just maintenance notes for whoever drops in new assets.
