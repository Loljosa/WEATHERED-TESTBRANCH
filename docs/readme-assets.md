# README assets

The README uses [Lucide](https://lucide.dev/) icons, [Shields.io](https://shields.io/) badges and a GitHub contribution calendar with optional [lowlighter/metrics](https://github.com/lowlighter/metrics) automation alongside the original WEATHERED logo.

## Lucide icons

The SVGs in [assets/icons/lucide](../assets/icons/lucide/) come from the official **lucide-static 1.54.0** npm package, matching upstream tag `1.54.0` at commit [`a04f228cd01185e09c188b7227b9600c08c565ec`](https://github.com/lucide-icons/lucide/commit/a04f228cd01185e09c188b7227b9600c08c565ec). No icon paths were drawn or changed. Only the root stroke color changes from `currentColor` to teal `#00A6A6`, so image tags display consistently on GitHub's light and dark backgrounds.

[manifest.json](../assets/icons/lucide/manifest.json) records the pinned package source, verified npm archive integrity and the original and local SHA-256 hashes for each SVG. The exact upstream [LICENSE](../assets/icons/lucide/LICENSE) is included: Lucide uses ISC, with an additional MIT notice for Feather-derived icons, including `arrow-up` and `terminal` in this selection. Keep that license and manifest when updating the icons.

The icons are local README images. They add no npm dependency, network request in Roblox or simulation work.

## Badges and contribution calendar

Shields.io supplies the README's project badges. The contribution calendar describes **Loljosa's GitHub account activity**, rather than engine measurements or project progress. Its public-data snapshot and optional pinned Metrics workflow are documented in [readme-metrics.md](readme-metrics.md). The WEATHERED logo is preserved separately from these third-party assets.
