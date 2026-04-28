# SolarLight

A tiny macOS Spotlight-style chat app for Solar and other OpenAI-compatible streaming chat backends.

## Requirements

- macOS 13 or later
- An Upstage API key, or credentials for another OpenAI-compatible chat provider

## Download and Install

1. Open the [latest SolarLight release](https://github.com/hunkim/SolarLight/releases/latest).
2. Download the `.dmg` file, for example `SolarLight-0.2.1.dmg`.
3. Open the DMG.
4. Drag `SolarLight.app` into the Applications folder.
5. Open SolarLight from Applications.
6. Click the gear button and enter your Upstage API key.

On first launch, macOS may ask you to confirm that you want to open an app downloaded from the internet.

SolarLight defaults to:

- Base URL: `https://web-search-api.toy.x.upstage.ai/v1`
- Model: `solar-pro3-search`

After setup, press `Cmd-L` to open or hide the floating search window.

## Use Another Provider

SolarLight works with OpenAI-compatible chat APIs. Open settings with the gear button and change:

- API key
- Base URL
- Model

For Upstage web search, use:

- Base URL: `https://web-search-api.toy.x.upstage.ai/v1`
- Model: `solar-pro3-search`

## Develop from Source

To run from source, install Xcode or Apple Command Line Tools, then clone the repo and run:

```sh
export OPENAI_API_KEY=<your_api_key>
export OPENAI_BASE_URL=<provider_base_url>
export OPENAI_MODEL=<provider_model>
swift run
```

For Upstage, you can also use:

```sh
export UPSTAGE_API_KEY=<your_upstage_api_key>
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
