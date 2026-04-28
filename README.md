# SolarLight

A tiny macOS Spotlight-style chat app for Solar and other OpenAI-compatible streaming chat backends.

## Run

Install Xcode or Apple Command Line Tools, then run:

```sh
export UPSTAGE_API_KEY=<your_upstage_api_key>
swift run
```

The default model is `solar-pro3` and the default base URL is `https://api.upstage.ai/v1`.
You can still set `OPENAI_API_KEY`, `OPENAI_MODEL`, and `OPENAI_BASE_URL` for any OpenAI-compatible provider.

On systems where the latest Command Line Tools expose a mismatched default SDK, use:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
CLANG_MODULE_CACHE_PATH=/tmp/solarlight-clang-cache \
swift run
```

For a Finder-launched `.app`, put the same values in `~/.solarlight.env`:

```sh
UPSTAGE_API_KEY=<your_upstage_api_key>
```

You can also set the API key, base URL, and model from the gear button inside the app.

To build a `.app` bundle:

```sh
chmod +x Scripts/package-app.sh
Scripts/package-app.sh
```

The bundle is created at `.build/SolarLight.app`.

## Use

- Press `Cmd-L` to open or hide the floating input.
- Type a prompt and pause briefly, or press `Return`.
- The response streams into the panel.
- Press `Esc` or click away to close it.

The app runs as an accessory app with a small menu bar item.
