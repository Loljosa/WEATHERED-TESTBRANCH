# Official Isocalendar integration

The README displays **Loljosa's account-wide GitHub contributions** using the official [lowlighter/metrics Isocalendar plugin](https://github.com/lowlighter/metrics/tree/master/source/plugins/isocalendar). It describes GitHub activity rather than WEATHERED progress, cloud coverage or simulation performance.

## Included official rendering

[assets/metrics/isocalendar.svg](../assets/metrics/isocalendar.svg) is produced by the actual upstream plugin from a real GitHub GraphQL contribution-calendar response. The pinned plugin is vendored without changes under [vendor/lowlighter-metrics/isocalendar](../vendor/lowlighter-metrics/isocalendar/), with its original MIT license and source hashes. The SVG retains the plugin's own geometry, colors and shading; only trailing whitespace and the outer negative margin used by the Classic card are removed for standalone display.

[isocalendar-source.json](../assets/metrics/isocalendar-source.json) records the real dates, counts, GitHub colors, capture timestamp, response hash and renderer version. Captured on **October 9, 2026**, it covers **October 5, 2025–October 8, 2026**: **369 days, 10 contributions, four active days**, and a maximum of five contributions in one day. The official full-year renderer aligns its start to Sunday and ends on the previous UTC day. No contribution values were fabricated and no token is stored in the snapshot.

The chart is available immediately after importing the files. Automatic refreshing is optional and runs separately on GitHub Actions.

## Reproduce the saved snapshot

Node.js, already required for the repository's npm tools, can run the renderer without installing another dependency:

```bash
node scripts/render-isocalendar.mjs --check
```

This verifies that the checked-in SVG matches the official rendering of the saved capture. The script verifies the pinned plugin hash, replays its date-range queries against the recorded real data, and fixes the clock to the recorded capture timestamp. It makes no network requests and reads no credentials.

To export the historical snapshot without replacing the README's current image:

```bash
mkdir -p build
node scripts/render-isocalendar.mjs --output build/isocalendar-snapshot.svg
```

After the scheduled workflow refreshes the image, `--check` may report a difference because the saved capture remains historical and the full Metrics action adds its Classic template. Use the separate output path to reproduce that original capture. Running the script without options regenerates `assets/metrics/isocalendar.svg` from the saved data.

## Enable daily updates

[.github/workflows/metrics.yml](../.github/workflows/metrics.yml) is configured for a full-year Isocalendar using account `Loljosa`. It runs at **04:17 UTC daily**, or manually through **Actions → README contribution calendar → Run workflow**, and commits the generated image to the existing `main` branch.

1. Push the latest files to this repository's `main` branch on GitHub.
2. Create a **classic** GitHub personal access token with **no scopes selected**, which is sufficient for public contribution data. The pinned Metrics version does not support fine-grained tokens.
3. Add it in **Settings → Secrets and variables → Actions → New repository secret**, named **`METRICS_TOKEN`**. Keep the value in GitHub's secret settings.
4. Run **README contribution calendar** from the Actions tab. Repository policy must permit the job's `contents: write` permission and commits to `main`.

`METRICS_TOKEN` reads account data; the automatic `${{ github.token }}` separately writes the SVG. Without the secret, the workflow leaves the included official snapshot intact and explains the missing setup in its summary. Plugin errors stop the update. Scheduled refreshes produce the full official Classic card, while the JSON remains provenance for the bundled capture.

Refresh commits use `github-actions[bot]`; authored project changes use **39GUN**. The workflow does not create branches and adds no Roblox runtime work.

## Pinned source and validation

Both the offline plugin and the workflow use Metrics **3.34.0**, commit [`65836723097537a54cd8eb90f61839426b4266b6`](https://github.com/lowlighter/metrics/commit/65836723097537a54cd8eb90f61839426b4266b6). The workflow builds the pinned source with `use_prebuilt_image: "no"`, rather than pulling a mutable prebuilt tag. It has no push trigger and skips commits when data has not changed.

Local validation covers fresh GraphQL data comparison, vendor/license hashes, deterministic rendering, SVG structure, light/dark/mobile previews and workflow linting. Actual GitHub Actions execution requires the repository secret and write access; it is separate from the successful offline rendering.

References: [plugin options](https://github.com/lowlighter/metrics/blob/65836723097537a54cd8eb90f61839426b4266b6/source/plugins/isocalendar/README.md), [upstream token setup](https://github.com/lowlighter/metrics/blob/65836723097537a54cd8eb90f61839426b4266b6/.github/readme/partials/documentation/setup/action.md), [action inputs](https://github.com/lowlighter/metrics/blob/65836723097537a54cd8eb90f61839426b4266b6/action.yml).
