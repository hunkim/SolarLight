# SolarLight

A tiny macOS Spotlight-style chat app for Solar and other OpenAI-compatible streaming chat backends.

## Requirements

- macOS 13 or later
- Xcode or Apple Command Line Tools
- An Upstage API key, or credentials for another OpenAI-compatible chat provider

## Quick Start

Clone the repo, set an API key, and run the app from the terminal:

```sh
export UPSTAGE_API_KEY=<your_upstage_api_key>
swift run
```

SolarLight defaults to:

- Base URL: `https://api.upstage.ai/v1`
- Model: `solar-pro3`

For another OpenAI-compatible provider, set:

```sh
export OPENAI_API_KEY=<your_api_key>
export OPENAI_BASE_URL=<provider_base_url>
export OPENAI_MODEL=<provider_model>
swift run
```

On systems where the latest Command Line Tools expose a mismatched default SDK, use:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
CLANG_MODULE_CACHE_PATH=/tmp/solarlight-clang-cache \
swift run
```

You can also set the API key, base URL, and model from the gear button inside the app.

## Build the App Bundle

To create a Finder-launchable `.app` bundle:

```sh
chmod +x Scripts/package-app.sh
Scripts/package-app.sh
```

The bundle is created at:

```sh
.build/SolarLight.app
```

Finder does not inherit your terminal environment. Before launching the `.app` directly, either save credentials in the app settings or create `~/.solarlight.env`:

```sh
UPSTAGE_API_KEY=<your_upstage_api_key>
```

The env file also supports `OPENAI_API_KEY`, `OPENAI_BASE_URL`, and `OPENAI_MODEL`.

## Build a Downloadable DMG

To create a downloadable disk image for GitHub releases:

```sh
chmod +x Scripts/package-dmg.sh
Scripts/package-dmg.sh
```

The DMG is created at:

```sh
.build/SolarLight.dmg
```

Set `SOLARLIGHT_VERSION` to include a version in the app metadata and DMG filename:

```sh
SOLARLIGHT_VERSION=0.1.0 Scripts/package-dmg.sh
```

That creates `.build/SolarLight-0.1.0.dmg`. Users can download the DMG, open it, and drag `SolarLight.app` into Applications.

This build is not notarized. On first launch, macOS may ask users to confirm they want to open an app downloaded from the internet.

## GitHub Releases

This repo includes a release workflow that builds `SolarLight.dmg`.

- Run it manually from the GitHub Actions tab to download the DMG as a workflow artifact.
- Push a version tag like `v0.1.0` to attach `SolarLight.dmg` to a GitHub Release.

## Use

- Press `Cmd-L` to open or hide the floating input.
- Type a prompt and pause briefly, or press `Return`.
- The response streams into the panel.
- Press `Esc` or click away to close it.

The app runs as an accessory app with a small menu bar item.

## Updates

When SolarLight is installed as a `.app`, it checks the latest GitHub Release when the panel opens. If a newer release includes a DMG, an Update button appears in the panel. Pressing it downloads the DMG, replaces the installed app, and relaunches SolarLight.

Updates are skipped when running from `swift run` or directly from a mounted DMG.
