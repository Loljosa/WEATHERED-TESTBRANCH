# README contribution calendar

The README calendar shows **Loljosa's GitHub contribution activity across the account**. It does not measure WEATHERED commits, simulation performance, cloud coverage or the project's completion rate.

## Included snapshot

The repository includes a calendar at [assets/metrics/isocalendar.svg](../assets/metrics/isocalendar.svg), generated from Loljosa's public GitHub contribution calendar. The recorded dates and public data source are in [isocalendar-source.json](../assets/metrics/isocalendar-source.json). This is a dated snapshot, so the README remains readable before automated updates are enabled.

The isometric presentation follows the [lowlighter/metrics full-year isocalendar](https://github.com/lowlighter/metrics/blob/examples/metrics.plugin.isocalendar.fullyear.svg). The example image belongs to another account; its activity was not copied into WEATHERED's calendar. Once configured, the official Metrics action replaces the bundled image with its own rendering of Loljosa's current contribution data. The JSON file continues to describe the original bundled snapshot.

## Optional automatic updates

[.github/workflows/metrics.yml](../.github/workflows/metrics.yml) runs daily at **04:17 UTC**, or manually through **Actions → README contribution calendar → Run workflow**. No setup is needed to display the included snapshot.

To enable automatic updates:

1. Create a **classic** GitHub personal access token with **no scopes selected**. Only public contribution data is needed. The pinned Metrics version does not support fine-grained tokens.
2. In this repository, open **Settings → Secrets and variables → Actions → New repository secret**, name it **`METRICS_TOKEN`**, and paste the token into its secret value. Keep the token out of files and commits.
3. Allow repository workflows to write contents, then run **README contribution calendar** from the Actions tab. If branch protection disallows automated commits to `main`, the image stays unchanged and Actions reports the failure.

The action uses `METRICS_TOKEN` to read GitHub account data. It uses the repository's automatic `${{ github.token }}` separately to commit the generated SVG on the existing `main` branch. Upstream requires a personal token for gathering account metrics; a repository-scoped token is not its supported substitute.

Without the secret, the workflow reports that updates are unconfigured and leaves the snapshot intact. Plugin failures stop the update rather than replacing the image with an error graphic. Refresh commits are made by `github-actions[bot]`; authored project changes use **39GUN**.

## Maintenance

The generator is pinned to Metrics **3.34.0**, commit [`65836723097537a54cd8eb90f61839426b4266b6`](https://github.com/lowlighter/metrics/commit/65836723097537a54cd8eb90f61839426b4266b6). `use_prebuilt_image: "no"` builds that source instead of pulling the mutable prebuilt image tag. Rendering runs on a GitHub-hosted runner and adds no Roblox or laptop runtime work.

The workflow writes only `assets/metrics/isocalendar.svg`, skips commits when the rendered data has not changed, and has no push trigger. It does not create branches. Update the pinned SHA deliberately when upgrading Metrics. The workflow configuration was checked against upstream's action inputs; executing it requires the repository secret and a GitHub Actions run.

References: [isocalendar plugin](https://github.com/lowlighter/metrics/blob/65836723097537a54cd8eb90f61839426b4266b6/source/plugins/isocalendar/README.md), [official setup and token requirements](https://github.com/lowlighter/metrics/blob/65836723097537a54cd8eb90f61839426b4266b6/.github/readme/partials/documentation/setup/action.md), [action inputs](https://github.com/lowlighter/metrics/blob/65836723097537a54cd8eb90f61839426b4266b6/action.yml).
