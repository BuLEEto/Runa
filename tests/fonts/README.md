# Test fonts

This directory is intentionally empty in the committed repo —
test fonts are fetched on demand by CI and by local contributors,
not bundled. Keeps the repo size small and dodges the OFL /
Apache-2.0 / CC-BY-4.0 attribution patchwork that committing every
file would require.

## What the test suite expects

| File | Source | Licence |
|---|---|---|
| `Roboto-Regular.ttf` | https://fonts.google.com/specimen/Roboto | Apache-2.0 |
| `InterVariable.ttf` | https://github.com/rsms/inter/releases | OFL-1.1 |
| `FiraCode-Regular.ttf` | https://github.com/tonsky/FiraCode/releases | OFL-1.1 |
| `JetBrainsMono-Regular.ttf` | https://github.com/JetBrains/JetBrainsMono/releases | OFL-1.1 |
| `SourceCodeVF.otf` | https://github.com/adobe-fonts/source-code-pro/releases | OFL-1.1 |
| `LinLibertine-Regular.otf` | http://www.linuxlibertine.org/ | GPL / OFL dual |
| `NotoSansArabic-Regular.ttf` | https://github.com/notofonts/arabic/releases | OFL-1.1 |
| `NotoSansHebrew-Regular.ttf` | https://github.com/notofonts/hebrew/releases | OFL-1.1 |
| `NotoColorEmoji.ttf` | https://github.com/googlefonts/noto-emoji/releases | OFL-1.1 |
| `NotoColorEmoji-COLRv1.ttf` | https://github.com/googlefonts/noto-emoji/releases (COLRv1 build) | OFL-1.1 |
| `Twemoji-Mozilla.ttf` | https://github.com/mozilla/twemoji-colr/releases | Apache-2.0 + CC-BY-4.0 |

## CI

`.github/workflows/ci.yml` fetches these files on a best-effort
basis before running the test job. If a fetch fails (network
hiccup, upstream URL change), the font-dependent tests skip
themselves with an INFO log and the job still reports
compile + synthetic-test results.

## Local development

Drop the files above into this directory before running the test
suite. Without them most `tests/parse/`, `tests/shape/`, and
`tests/golden/` tests skip; the synthetic harnesses still run.
