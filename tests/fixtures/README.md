# Test fixtures

## `narration.wav` — short test narration

A ~3.5 second WAV (16 kHz mono PCM) of the phrase
"Hello from GuiAssert D-ID. This is a test render.", generated via
macOS `say` and resampled with `ffmpeg`:

```
say -o tmp.aiff "Hello from GuiAssert D-ID. This is a test render."
ffmpeg -i tmp.aiff -ar 16000 -ac 1 narration.wav
```

The narration is reused from the sibling D-ID plugin's fixture
directory for cross-plugin consistency. Synthesia does **not** consume
audio uploads on its `POST /v2/videos` endpoint — the narration text
is supplied by `opts.providerSettings["script_text"]` and Synthesia
synthesises the voice itself. This WAV is therefore used only as a
cache-key ingredient by the plugin (via `cacheKeyFor`), not as content
uploaded to Synthesia. See the README for the full rationale.

The live test honours `$GUI_ASSERT_SYNTHESIA_TEST_WAV` as an override.
