# GuiAssert-Synthesia

Synthesia talking-head plugin for [GuiAssert]. Implements GuiAssert's
`TalkingHeadProvider` contract by speaking the commercial
[Synthesia v2 REST API](https://docs.synthesia.io/reference/create-video)
— no Python, no model weights, no GPU toolchain. Pure-Nim HTTP client.

Synthesia is a commercial enterprise-focused avatar-video service.
Compared with the local-ML siblings (`GuiAssert-Wav2Lip`,
`GuiAssert-MuseTalk`, `GuiAssert-SadTalker`) and the sibling commercial
plugins (`GuiAssert-Did`, `GuiAssert-HeyGen`), it trades a recurring
subscription fee for zero install cost and zero local compute — but
with enterprise-tier pricing.

[GuiAssert]: ../GuiAssert/

## Layout

```
GuiAssert-Synthesia/
├── flake.nix                               nim + ffmpeg-full + openssl + cacert devShell (no Python)
├── gui_assert_synthesia.nimble             nimble package
├── src/
│   └── gui_assert_synthesia.nim            plugin implementation (TalkingHeadProvider)
└── tests/
    ├── fixtures/
    │   ├── README.md                       fixture provenance
    │   └── narration.wav                   ~3.5 s test WAV (cache-key ingredient only)
    └── tsynthesia.nim                      pure + mock-server tests + `-d:synthesiaLive` gated live test
```

## Cost of setup

| Resource     | Approx.                                                |
| ------------ | ------------------------------------------------------ |
| Disk         | None beyond Nim build artefacts                        |
| Network      | Per-render JSON + MP4 download, modest                 |
| Time         | First call ~minutes (Synthesia renders are slow)       |
| Dollars      | **Starter $29/mo, Creator $89/mo, Enterprise custom**. API access typically requires the **Creator+ plan**; the Starter tier is web-UI-only. Within a plan, renders are quota-metered (minutes/month) rather than pay-as-you-go per call. |
| API key      | Yes — `SYNTHESIA_API_KEY` env var                      |

Pricing is set by Synthesia; see [their pricing page](https://www.synthesia.io/pricing)
for current numbers and the per-tier monthly render quota. The
plugin's `test: true` sandbox flag (the default) produces watermarked
output that does NOT count against the quota — useful for CI runs
that need to exercise the real API without burning minutes.

## Setup

```sh
nix develop
export SYNTHESIA_API_KEY="..."   # from https://app.synthesia.io → Account → API
```

No install script. No model weights. The `nix develop` shell
provisions Nim, ffmpeg (for fixture synthesis + ffprobe validation),
OpenSSL, and a CA bundle so TLS to `api.synthesia.io` works without
user setup.

## Important deviation from the generic contract

GuiAssert's `TalkingHeadProvider.generate` contract is
`generate(narrationWav, outputMp4, opts)` — i.e. the audio is provided
as a *pre-rendered WAV*. Synthesia's `POST /v2/videos` endpoint does
NOT accept uploaded audio: it takes a `scriptText` string and
synthesises the voiceover itself (Synthesia ships its own
avatar-aware TTS). This plugin therefore:

- IGNORES the `narrationWav` parameter for the actual API call.
- REQUIRES `opts.providerSettings["script_text"]` to be set to the
  string Synthesia should speak. `generate` raises `TalkingHeadError`
  if missing or empty.

The `narrationWav` is still incorporated into the on-disk cache key,
so consumers can carry per-session uniqueness in the WAV (e.g. by
passing a unique audio file per render call). The cache key also
folds in `script_text`, `avatar`, `background`, `title`, and the
`test` flag, so two different scripts on the same WAV do not collide.

The same deviation applies to the sibling HeyGen plugin — both
commercial providers synthesise their own voice from text rather than
honouring uploaded audio.

## Authentication quirk

Synthesia authenticates with the standard HTTP `Authorization` header
— but carrying the **raw API key**, with no `Bearer ` or `Basic `
prefix:

```
Authorization: 0123abcd-your-synthesia-key
```

This is unusual: D-ID uses HTTP Basic auth, HeyGen uses a custom
`X-Api-Key` header, and most REST APIs follow RFC 6750
(`Bearer <token>`). The plugin pins the raw-key form intentionally;
the pure tests guard against accidental "fixes" that would prepend a
Bearer prefix.

## Wiring into a runner

```nim
import gui_assert/talking_head
import gui_assert_synthesia

let reg = newRegistry()         # registry pre-populated with `stock_avatar`
registerSynthesia(reg)          # now `synthesia` is also registered

var opts = TalkingHeadOpts(
  avatarImagePath: none(string),    # unused by Synthesia (avatar is server-side)
  device: "auto",
  cacheDir: some("/tmp/synthesia-cache"),
  providerSettings: %*{
    "script_text": "Hello from GuiAssert Synthesia.",
    "avatar": "anna_costume1_cameraA",     # public stock avatar
    "background": "white_studio",
    "title": "Demo render",
    "test": true,                          # sandbox render (no quota use)
    # api_key falls back to $SYNTHESIA_API_KEY
  },
)
generateTalkingHead(reg, "synthesia", narrationWav, outputMp4, opts)
```

### Configuration

All knobs live under `TalkingHeadOpts.providerSettings` (a `JsonNode`),
with environment-variable fallbacks where applicable:

| Setting | YAML key | Env fallback | Default | Purpose |
| --- | --- | --- | --- | --- |
| `api_key` | `api_key` | `SYNTHESIA_API_KEY` | _(none)_ | Synthesia API key (raw, no prefix). |
| `api_base` | `api_base` | _(none)_ | `https://api.synthesia.io` | API endpoint. Override to point at a mock or staging server. |
| `script_text` | `script_text` | _(none)_ | _(none)_ | **REQUIRED.** Script for Synthesia to speak. |
| `avatar` | `avatar` | _(none)_ | `anna_costume1_cameraA` | Synthesia avatar identifier (public stock or custom). |
| `background` | `background` | _(none)_ | `white_studio` | Synthesia background identifier. |
| `title` | `title` | _(none)_ | `GuiAssert Synthesia render` | Display title for the rendered video. |
| `test` | `test` | _(none)_ | `true` | Sandbox render (watermarked, no quota use). Set `false` to spend real quota. |

The provider name is `"synthesia"`.

## API flow

The provider performs three sequential interactions per render (plus
poll round-trips):

1. `POST /v2/videos` — JSON body of the form documented in
   Synthesia's quick-start:
   ```json
   {
     "test": true,
     "input": [{
       "scriptText": "Hello, this is Synthesia.",
       "avatar": "anna_costume1_cameraA",
       "background": "white_studio"
     }],
     "title": "Demo render"
   }
   ```
   Note that `scriptText` is camelCase (per Synthesia's docs), not
   snake_case like the rest of the API ecosystem. The response is a
   flat JSON object `{"id": "...", "status": "in_progress", ...}` —
   no envelope wrapping (unlike HeyGen).
2. `GET /v2/videos/{id}` — polled every 10 s (15-minute timeout)
   until `status == "complete"`. Synthesia renders are slow; the
   timeout is more generous than the other commercial siblings.
3. `GET <download>` — downloads the MP4 to disk. The CDN URL does
   not require the `Authorization` header.

Authentication uses the Synthesia-specific raw-key
`Authorization: <SYNTHESIA_API_KEY>` header. (Notably *not*
`Bearer <token>`, *not* HTTP Basic, and *not* `X-Api-Key`.)

## Caching

The plugin reuses GuiAssert's generic on-disk cache
(`applyCache` + `cacheKeyFor`). Because Synthesia's "avatar" is
purely server-side (an avatar string, not a local file) and its
"narration" is purely server-side too (a `script_text` string,
synthesised remotely), the cache key folds the Synthesia-specific
knobs (`script_text`, `avatar`, `background`, `title`, `test`) into
the device slot via a SHA-1 prefix. Identical inputs short-circuit
the API calls entirely on the second invocation. This is doubly
important here because every cache hit avoids spending render quota.

The mock-server test validates the cache-hit path: a second
`generate` call against the same inputs issues zero HTTP requests.

## Tests

```sh
# Pure unit tests + mock-server integration test — no network.
nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/tsynthesia.nim

# Live end-to-end against api.synthesia.io — requires SYNTHESIA_API_KEY.
nim c -d:synthesiaLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/tsynthesia.nim
```

The `--threads:on` flag is required because the mock-server test
spawns a thread that drives `asyncdispatch.poll()` while the main
thread issues blocking `std/httpclient` calls.

The mock-server suite spins up a `std/asynchttpserver` on a random
localhost port, records every request the provider issues (method,
path, headers, body), and asserts:

- Every API request carries the `Authorization` header set to the
  test key (`DUMMY_KEY`) — raw, with no `Bearer ` prefix.
- `POST /v2/videos` carries exactly the JSON shape Synthesia
  documents (camelCase `input[0].scriptText`, `input[0].avatar`,
  `input[0].background`, top-level `title` + `test`).
- Polling cadence is respected (the provider does not short-circuit
  while status is `in_progress`).
- The downloaded MP4 is byte-identical to the mock's golden file.
- A second call hits the on-disk cache and issues zero HTTP traffic.
- Changing `script_text` forces a fresh render (different cache key).

The live test fails the run if `SYNTHESIA_API_KEY` is missing — per
project policy, there are no graceful skips. CI that does not want
to spend real Synthesia quota simply compiles without
`-d:synthesiaLive`.

## License

MIT — see `LICENSE`. Synthesia itself is a commercial service governed
by its own [terms of service](https://www.synthesia.io/legal-and-policies/terms-of-service);
the plugin only speaks the public REST API.
