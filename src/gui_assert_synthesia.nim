## Synthesia talking-head plugin for GuiAssert.
##
## Implements GuiAssert's `TalkingHeadProvider` contract on top of the
## commercial Synthesia v2 REST API
## (https://docs.synthesia.io/reference/create-video). Like the sibling
## D-ID and HeyGen plugins this is a pure-Nim HTTP client — no Python,
## no model weights, no GPU toolchain. Like HeyGen, Synthesia
## synthesises its own voice from a text input on `POST /v2/videos`;
## there is no audio-upload mode in the default flow.
##
## ## Wire shape
##
##   * `synthesiaProvider()` builds a `TalkingHeadProvider` value with
##     `name = "synthesia"`, an `isAvailable` check (is
##     `SYNTHESIA_API_KEY` set?), and a `generate` proc that performs
##     the create / poll / download cycle.
##   * `registerSynthesia(reg)` is the one-liner plugin registration
##     entry point.
##
## ## Important deviation from the generic contract
##
## The `TalkingHeadProvider.generate` contract is
## `generate(narrationWav, outputMp4, opts)` — i.e. the *audio is
## provided as a pre-rendered WAV*. Synthesia's `POST /v2/videos`
## endpoint does NOT accept uploaded audio; it takes a `scriptText`
## string and synthesises the voiceover internally (Synthesia ships its
## own avatar-aware TTS). This plugin therefore:
##
##   * IGNORES the `narrationWav` parameter for the actual API call,
##     and
##   * REQUIRES `opts.providerSettings["script_text"]` (a string) to be
##     present.
##
## The `narrationWav` parameter is still hashed into the cache key, so
## consumers can carry per-session uniqueness in the WAV (e.g. by
## passing a unique audio file per render call). This keeps the cache
## key compatible with the rest of the GuiAssert ecosystem while making
## the Synthesia plugin a drop-in for the same call sites the local-ML
## plugins use.
##
## ## Configuration
##
## All knobs are read from `TalkingHeadOpts.providerSettings` (a
## JsonNode), falling back to environment variables / sensible
## defaults:
##
##   * `api_key` — Synthesia API key. Falls back to
##     `$SYNTHESIA_API_KEY`. `isAvailable()` returns false when neither
##     is set.
##   * `api_base` — API base URL. Defaults to
##     `https://api.synthesia.io`. Tests point this at a local
##     `std/asynchttpserver` mock so the full create / poll / download
##     cycle is exercised without network.
##   * `script_text` — the script Synthesia should speak. REQUIRED;
##     `generate` raises `TalkingHeadError` if missing/empty.
##   * `avatar` — Synthesia avatar identifier. Defaults to
##     `anna_costume1_cameraA` (a public stock avatar).
##   * `background` — Synthesia background identifier. Defaults to
##     `white_studio`.
##   * `title` — display title for the rendered video. Defaults to
##     `GuiAssert Synthesia render`.
##   * `test` — boolean. When true (the default) Synthesia renders a
##     watermarked sandbox video that does NOT consume render quota.
##     Live tests can flip this to false to spend real quota.
##
## ## API flow
##
##   1. `POST /v2/videos` (JSON) — creates the video job. The JSON body
##      carries an `input[]` array with one entry holding `scriptText`
##      (camelCase, per Synthesia's docs), `avatar`, and `background`,
##      plus a top-level `title` and a `test` boolean. The response is
##      a flat JSON object with `id` + `status` (no envelope).
##   2. `GET /v2/videos/{id}` — polled every `intervalMs` until the
##      status reaches `complete` (or `failed` / `rejected`). Response
##      shape: `{"id": ..., "status": ..., "download": "..."}`. The
##      download URL is populated only when status is `complete`.
##      Honours a 15-minute timeout — Synthesia renders are often the
##      slowest of the commercial pack.
##   3. `GET <download>` — downloads the rendered MP4 to disk. The
##      download URL is served from Synthesia's CDN and does NOT
##      require the auth header.
##
## ## Authentication quirk
##
## Synthesia's authentication header is `Authorization: <api_key>` —
## the RAW key, with NO `Bearer ` or `Basic ` prefix. This is unusual
## (HeyGen uses `X-Api-Key`; D-ID uses HTTP Basic), and is documented
## here so future maintainers don't "fix" it into a Bearer token.
##
## Errors at any step raise `SynthesiaError` with the HTTP status code
## and (when present) the response body excerpt.

import std/[os, options, json, httpclient, sha1, strutils, times]

import gui_assert/talking_head
import gui_assert/emotive

type
  SynthesiaError* = object of TalkingHeadError
    ## Raised by the low-level HTTP entry points. Subclasses
    ## `TalkingHeadError` so the generic dispatch in
    ## `gui_assert/talking_head` can catch it uniformly.

const
  ProviderName* = "synthesia"
  DefaultSynthesiaApiBase* = "https://api.synthesia.io"
  DefaultMaxPollSecs* = 900.0
    ## Synthesia renders can take several minutes; we give 15 minutes
    ## of slack before giving up. This is the per-request wall-clock
    ## cap on the polling loop, not the HTTP request timeout.
  DefaultPollIntervalMs* = 10_000
  DefaultSynthesiaAvatar* = "anna_costume1_cameraA"
    ## Synthesia public stock avatar. Documented in the v2 quick-start.
  DefaultSynthesiaBackground* = "white_studio"
    ## Synthesia public stock background. Documented in the v2
    ## quick-start.
  DefaultTitle* = "GuiAssert Synthesia render"
  DefaultTestRender* = true
    ## Default to Synthesia's `test: true` sandbox mode: watermarked
    ## output that does NOT consume render quota. Production callers
    ## opt in to real renders by passing `"test": false` in
    ## `providerSettings`.
  ApiKeyEnvVar* = "SYNTHESIA_API_KEY"
  ApiBaseSetting* = "api_base"
  ApiKeySetting* = "api_key"
  ScriptTextSetting* = "script_text"
  AvatarSetting* = "avatar"
  BackgroundSetting* = "background"
  TitleSetting* = "title"
  TestSetting* = "test"

# ---------------------------------------------------------------------------
# Pure helpers — testable without any network access.
# ---------------------------------------------------------------------------

proc synthesiaAuthHeader*(apiKey: string): HttpHeaders =
  ## Build the auth header table Synthesia expects. Synthesia uses a
  ## standard HTTP `Authorization` header — but with the RAW API key
  ## (no `Bearer ` or `Basic ` prefix). This is a quirky deviation
  ## from RFC 6750 / RFC 7617 and is intentional; future maintainers
  ## should NOT "fix" it into a Bearer token. We pin
  ## `Content-Type: application/json` alongside because every
  ## authenticated Synthesia request from this plugin sends a JSON
  ## body (or, for `GET /v2/videos/{id}`, no body — the
  ## Content-Type is harmless on a GET).
  newHttpHeaders({"Authorization": apiKey, "Content-Type": "application/json"})

proc buildCreateVideoBody*(scriptText, avatar, background, title: string;
                           test = DefaultTestRender): JsonNode =
  ## Construct the JSON body for `POST /v2/videos`. Mirrors the
  ## documented v2 quick-start shape exactly: a single-element
  ## `input` array whose only element carries `scriptText` (camelCase,
  ## per the Synthesia docs), `avatar`, and `background`. The
  ## top-level `title` is the human-readable display name; `test`
  ## toggles Synthesia's no-quota sandbox render.
  result = %*{
    "test": test,
    "input": [{
      "scriptText": scriptText,
      "avatar": avatar,
      "background": background
    }],
    "title": title
  }

proc resolveApiKey*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_key`, then the
  ## `$SYNTHESIA_API_KEY` env var, then "" (signalling unavailability).
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiKeySetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = getEnv(ApiKeyEnvVar)

proc resolveApiBase*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_base`, then the
  ## `DefaultSynthesiaApiBase` constant. Trailing slashes are stripped
  ## so downstream string-concatenation stays predictable.
  var base = DefaultSynthesiaApiBase
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiBaseSetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      base = n.getStr
  while base.endsWith('/'):
    base.setLen(base.len - 1)
  result = base

proc resolveStringSetting(opts: TalkingHeadOpts, key, default: string): string =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = default

proc resolveBoolSetting(opts: TalkingHeadOpts, key: string, default: bool): bool =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil:
      case n.kind
      of JBool: return n.getBool
      of JString:
        case n.getStr.toLowerAscii
        of "true", "1", "yes", "on": return true
        of "false", "0", "no", "off": return false
        else: discard
      else: discard
  result = default

proc resolveScriptText*(opts: TalkingHeadOpts): string =
  ## Read `opts.providerSettings.script_text`. Synthesia has no env-var
  ## fallback for the script — it is structurally part of the per-call
  ## payload. Returns "" when missing; the caller is expected to raise
  ## a `TalkingHeadError` in that case.
  resolveStringSetting(opts, ScriptTextSetting, "")

proc resolveAvatar*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, AvatarSetting, DefaultSynthesiaAvatar)

proc resolveBackground*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, BackgroundSetting, DefaultSynthesiaBackground)

proc resolveTitle*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, TitleSetting, DefaultTitle)

proc resolveTest*(opts: TalkingHeadOpts): bool =
  resolveBoolSetting(opts, TestSetting, DefaultTestRender)

proc shortHashOf(s: string): string =
  ## 16-hex-char SHA-1 prefix — used to fold the Synthesia-specific
  ## knobs (script_text, avatar, background, title, test) into the
  ## cache-key device slot. See `synthesiaCacheSalt`.
  let d = secureHash(s)
  let full = $d
  result = full[0 ..< 16].toLowerAscii

proc synthesiaCacheSalt*(device, scriptText, avatar, background,
                         title: string; test: bool): string =
  ## Per-call cache discriminator. `cacheKeyFor`'s signature is fixed
  ## by the GuiAssert contract (avatar + narration + provider + device)
  ## — for Synthesia the "avatar" is server-side (an avatar identifier
  ## string), and the actual narration is the `script_text` string, so
  ## we fold the Synthesia-specific knobs into the `device` slot. Two
  ## different script_text values for the same WAV therefore produce
  ## different cache entries; identical inputs short-circuit the API
  ## calls.
  ##
  ## Returned as `<device>|<sha1prefix>` so debug dumps stay legible.
  let mix = scriptText & "|" & avatar & "|" & background & "|" &
            title & "|" & (if test: "test" else: "live")
  result = device.toLowerAscii & "|" & shortHashOf(mix)

# ---------------------------------------------------------------------------
# HTTP client construction.
# ---------------------------------------------------------------------------

proc newSynthesiaHttpClient*(apiKey: string, timeoutMs = 60_000): HttpClient =
  ## Build an `HttpClient` pre-configured with the Synthesia raw-key
  ## `Authorization` header. We pin `Connection: close` so each call
  ## opens a fresh TCP socket — this sidesteps the same
  ## `std/asynchttpserver` keep-alive race the sibling D-ID and HeyGen
  ## plugins document, and helps real-world upstream proxies that drop
  ## idle sockets during the polling sleep gap.
  let headers = newHttpHeaders({
    "Authorization": apiKey,
    "Accept": "application/json",
    "Content-Type": "application/json",
    "User-Agent": "GuiAssert-Synthesia/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
    "Connection": "close",
  })
  result = newHttpClient(timeout = timeoutMs, headers = headers)

proc closeQuietly(client: HttpClient) =
  ## Best-effort close — swallows OSError from already-closed sockets
  ## so callers don't have to wrap every defer in a try.
  try: client.close()
  except CatchableError: discard

template withFreshClient(apiKey: string, body: untyped): untyped =
  ## Build a one-shot HttpClient, run `body` with it bound to
  ## `client`, and close it afterwards. The block-scoped name makes
  ## the per-call client easy to spot vs. any long-lived provider
  ## client. Used to dodge keep-alive issues in the mock server +
  ## upstream proxies.
  block:
    let client {.inject.} = newSynthesiaHttpClient(apiKey)
    try:
      body
    finally:
      closeQuietly(client)

# ---------------------------------------------------------------------------
# Low-level HTTP entry points. Each one performs exactly one Synthesia
# API call and raises `SynthesiaError` on non-2xx responses. They are
# kept parameter-driven (apiBase passed in) so tests can point them at
# a localhost mock without touching globals.
# ---------------------------------------------------------------------------

proc raiseHttp(prefix: string, resp: Response) {.noreturn.} =
  ## Helper for surfacing non-2xx HTTP responses with body context.
  var body = ""
  try: body = resp.body
  except CatchableError: discard
  let excerpt =
    if body.len > 800: body[0 ..< 800] & " ...(truncated)"
    else: body
  raise newException(SynthesiaError,
    prefix & ": HTTP " & resp.status & "\n" & excerpt)

proc createVideo*(apiKey, apiBase: string, body: JsonNode): string =
  ## `POST /v2/videos`. Returns the Synthesia `id`. The body is
  ## whatever `buildCreateVideoBody` produced (the caller is free to
  ## hand-craft it for advanced flows).
  ##
  ## Each call opens a fresh `HttpClient` via the same template the
  ## polling loop uses — keep-alive races would otherwise show up as
  ## ProtocolError after the response socket is closed by the server.
  ##
  ## Synthesia's JSON response is a flat object (no envelope), shaped
  ## like `{"id": "...", "status": "in_progress", ...}`.
  var videoId: string
  withFreshClient(apiKey):
    let url = apiBase & "/v2/videos"
    let resp = client.request(url, httpMethod = HttpPost, body = $body)
    if not resp.code.is2xx:
      raiseHttp("POST /v2/videos", resp)
    let parsed =
      try: parseJson(resp.body)
      except JsonParsingError as e:
        raise newException(SynthesiaError,
          "POST /v2/videos: bad JSON: " & e.msg &
          "\nBody: " & resp.body)
    if parsed.kind != JObject:
      raise newException(SynthesiaError,
        "POST /v2/videos: expected JSON object, got " & $parsed.kind &
        ": " & resp.body)
    let idNode = parsed{"id"}
    if idNode.isNil or idNode.kind != JString or idNode.getStr.len == 0:
      raise newException(SynthesiaError,
        "POST /v2/videos: response missing id: " & resp.body)
    videoId = idNode.getStr
  result = videoId

proc getVideoStatusOnce*(apiKey, apiBase, videoId: string): JsonNode =
  ## Single `GET /v2/videos/{id}` round-trip. Returns the parsed JSON
  ## object so callers can read both `status` and `download` (the
  ## latter populated only when status reaches `complete`).
  ##
  ## Exposed for tests that want to inspect a single poll without the
  ## sleep loop.
  var parsed: JsonNode
  withFreshClient(apiKey):
    let url = apiBase & "/v2/videos/" & videoId
    let resp = client.request(url, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET /v2/videos/{id}", resp)
    try:
      parsed = parseJson(resp.body)
    except JsonParsingError as e:
      raise newException(SynthesiaError,
        "GET /v2/videos/{id}: bad JSON: " & e.msg &
        "\nBody: " & resp.body)
    if parsed.kind != JObject:
      raise newException(SynthesiaError,
        "GET /v2/videos/{id}: expected JSON object, got " & $parsed.kind &
        ": " & resp.body)
  result = parsed

proc pollVideoStatus*(apiKey, apiBase, videoId: string,
                     maxSecs = DefaultMaxPollSecs,
                     intervalMs = DefaultPollIntervalMs): string =
  ## `GET /v2/videos/{id}` until `status: complete` or
  ## `status: failed`/`rejected`, subject to a `maxSecs` wall-clock
  ## cap. Returns the `download` URL from which the rendered MP4 can
  ## be downloaded.
  let deadline = epochTime() + maxSecs
  while true:
    let parsed = getVideoStatusOnce(apiKey, apiBase, videoId)
    let status =
      if parsed{"status"}.isNil: ""
      else: parsed{"status"}.getStr
    case status
    of "complete":
      let urlNode = parsed{"download"}
      if urlNode.isNil or urlNode.kind != JString or urlNode.getStr.len == 0:
        raise newException(SynthesiaError,
          "Synthesia video " & videoId &
          ": status=complete but no download URL: " & $parsed)
      return urlNode.getStr
    of "failed", "rejected":
      raise newException(SynthesiaError,
        "Synthesia video " & videoId & " " & status & ": " & $parsed)
    else:
      discard
    if epochTime() >= deadline:
      raise newException(SynthesiaError,
        "Synthesia video " & videoId & " did not reach status=complete within " &
        $maxSecs & "s (last status=" & status & ")")
    sleep(intervalMs)

# ---------------------------------------------------------------------------
# Capabilities + emotive translation + discovery + dry-run
# ---------------------------------------------------------------------------

const SynthesiaCapabilities* = ProviderCapabilities(
  supportsEmotion: false,          ## emotion baked into avatar variant
  supportsHeadMotion: false,
  supportsExpressionScale: false,
  supportsGreenScreen: true,       ## background: "green_screen"
  supportsTransparentBg: false,
  supportsAudioInput: false,
  supportsTextInput: true,
  supportsVoiceTuning: false,
  supportsGestures: false,
  supportsEyeContact: false,
  supportedEmotions: @[],
)

proc emotiveToProviderSettings*(c: CommonEmotiveConfig;
                                base: JsonNode = nil): JsonNode =
  ## Project a `CommonEmotiveConfig` onto Synthesia's flat
  ## providerSettings dialect.  The only field the backend really
  ## exposes is `background`; everything else is avatar-driven and
  ## gets recorded into the cache salt for memoisation but not sent
  ## upstream.
  result = if base.isNil or base.kind != JObject: newJObject() else: base
  if c.background.isSome:
    case c.background.get
    of bmGreenScreen:
      setIfMissing(result, "background", %"green_screen")
    of bmSolidColor, bmTransparent, bmAsIs, bmTrained:
      if c.backgroundColor.isSome:
        setIfMissing(result, "background_color", %c.backgroundColor.get)

proc applyBackgroundToBody*(body: JsonNode, c: CommonEmotiveConfig) =
  ## Mutate a `POST /v2/videos` body so `input[0].background` is set
  ## from the common emotive config.  Synthesia accepts:
  ##
  ##   * `"green_screen"` — solid green canvas the downstream chroma-
  ##     key compose pipeline expects.
  ##   * `"transparent"` — alpha-channel render where the account
  ##     plan supports it.
  ##   * Any other string — looked up as an account-scoped background
  ##     name (e.g. `white_studio`).
  if body.isNil or body.kind != JObject: return
  if c.background.isNone: return
  let input = body["input"][0]
  case c.background.get
  of bmGreenScreen:
    input["background"] = %"green_screen"
  of bmTransparent:
    input["background"] = %"transparent"
  of bmSolidColor, bmAsIs, bmTrained: discard

proc parseGenderField(node: JsonNode): Gender =
  if node.isNil or node.kind != JString: return gUnspecified
  parseGender(node.getStr)

proc listAvatars*(apiKey: string;
                  apiBase: string = DefaultSynthesiaApiBase):
    seq[AvatarInfo] =
  ## `GET /v2/avatars` — paginated catalogue of avatars the supplied
  ## key is allowed to use.  We pull the first page (default 100
  ## entries) and normalise onto `AvatarInfo`.  Pagination beyond
  ## that is an explicit non-goal here — Synthesia's avatar count is
  ## measured in dozens for the public tier.
  result = @[]
  if apiKey.len == 0:
    raise newException(SynthesiaError,
      "listAvatars: SYNTHESIA_API_KEY is required")
  let client = newSynthesiaHttpClient(apiKey)
  try:
    let resp = client.request(apiBase & "/v2/avatars?limit=100",
                              httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET /v2/avatars", resp)
    let parsed = parseJson(resp.body)
    var list: JsonNode = nil
    if parsed.kind == JObject:
      if parsed.hasKey("avatars"): list = parsed["avatars"]
      elif parsed.hasKey("data"): list = parsed["data"]
    elif parsed.kind == JArray:
      list = parsed
    if list.isNil or list.kind != JArray: return
    for it in list.items:
      if it.kind != JObject: continue
      var a = AvatarInfo()
      a.id = it{"id"}.getStr("")
      if a.id.len == 0:
        a.id = it{"avatar_id"}.getStr("")
      a.name = it{"name"}.getStr("")
      if a.name.len == 0:
        a.name = it{"avatar_name"}.getStr("")
      a.gender = parseGenderField(it{"gender"})
      a.description = it{"description"}.getStr("")
      a.previewUrl = it{"preview"}.getStr("")
      if a.previewUrl.len == 0:
        a.previewUrl = it{"preview_video_url"}.getStr("")
      if it.hasKey("tags") and it["tags"].kind == JArray:
        for t in it["tags"].items:
          if t.kind == JString: a.tags.add t.getStr
      result.add a
  finally:
    closeQuietly(client)

proc dryRunValidate*(opts: TalkingHeadOpts;
                     prefs: AvatarPreferences = AvatarPreferences()):
    DryRunReport =
  ## Validate without spending render minutes.  Because Synthesia
  ## already offers `test: true` sandbox renders that don't deduct
  ## from quota, the dry-run focuses on local + lookup checks:
  ## API key, script_text non-empty, avatar id resolves either via
  ## `prefs` or `opts`, and the resolved id is present in the
  ## account's avatar list.
  result = newDryRunReport("synthesia")
  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    result.addIssue(drError, "api_key",
      "SYNTHESIA_API_KEY is not set (or providerSettings.api_key is empty)")
    return
  let apiBase = resolveApiBase(opts)
  let scriptText = resolveScriptText(opts)
  if scriptText.strip.len == 0:
    result.addIssue(drError, "script_text",
      "providerSettings.script_text is empty; Synthesia returns HTTP 400 " &
      "on empty narration")
  var avatarId = resolveAvatar(opts)
  var available: seq[AvatarInfo] = @[]
  try:
    available = listAvatars(apiKey, apiBase)
  except CatchableError as e:
    result.addIssue(drWarning, "avatars",
      "could not list avatars: " & e.msg)
  if prefs.preferred.len > 0 and available.len > 0:
    let m = matchPreferredAvatar(prefs, "synthesia", available)
    if m.isSome:
      avatarId = m.get.id
    else:
      result.addIssue(drWarning, "avatar_preferences",
        "no preferred avatar matched; using opts default '" & avatarId & "'")
  if available.len > 0:
    var hit = false
    for a in available:
      if a.id == avatarId or a.name == avatarId:
        hit = true; break
    if not hit:
      result.addIssue(drError, "avatar",
        "avatar '" & avatarId & "' is not in the account's avatar list")

proc downloadVideo*(videoUrl, outputPath: string) =
  ## Download the rendered MP4. The Synthesia `download` URL is served
  ## from a CDN and does NOT require the `Authorization` header; we
  ## open a vanilla `HttpClient` (no auth) for the download to keep
  ## the request as plain as possible AND to guard against accidental
  ## credential leakage to a third-party CDN host.
  let outParent = outputPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  let client = newHttpClient(timeout = 120_000,
                             headers = newHttpHeaders({
                               "User-Agent":
                                 "GuiAssert-Synthesia/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
                               "Connection": "close",
                             }))
  try:
    let resp = client.request(videoUrl, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET " & videoUrl, resp)
    writeFile(outputPath, resp.body)
    if not fileExists(outputPath) or getFileSize(outputPath) == 0:
      raise newException(SynthesiaError,
        "Synthesia result download produced no bytes at " & outputPath)
  finally:
    closeQuietly(client)

# ---------------------------------------------------------------------------
# Provider integration. Glues the HTTP layer to GuiAssert's contract.
# ---------------------------------------------------------------------------

proc synthesiaIsAvailable*(): bool {.gcsafe.} =
  ## True iff a Synthesia API key is set in the environment. We can't
  ## check the per-call `opts.providerSettings.api_key` here because
  ## `isAvailable` is parameterless by contract; the provider's
  ## `generate` proc re-resolves the key (including the YAML override
  ## path) and raises a clear error if the resolved key is empty.
  getEnv(ApiKeyEnvVar).len > 0

proc synthesiaGenerateImpl(narrationWav, outputMp4: string,
                          opts: TalkingHeadOpts,
                          maxPollSecs: float,
                          pollIntervalMs: int) {.gcsafe.} =
  ## Real `generate` body, parameterised on the polling cadence so the
  ## mock-server test can run the full create / poll / download cycle
  ## in milliseconds. The public `generateSynthesia` proc forwards to
  ## here with the production defaults.
  ##
  ## NOTE: `narrationWav` is intentionally *not uploaded*. Synthesia's
  ## `POST /v2/videos` synthesises its own voice from `scriptText`. We
  ## still validate the WAV exists because it is hashed into the cache
  ## key — see the module-level docstring for the rationale.
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "synthesia provider: narration WAV not found: " & narrationWav)

  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    raise newException(TalkingHeadError,
      "synthesia provider: API key not set. Either export " &
      "SYNTHESIA_API_KEY=<key> or pass it via " &
      "TalkingHeadOpts.providerSettings.api_key.")
  let apiBase = resolveApiBase(opts)
  let scriptText = resolveScriptText(opts)
  if scriptText.len == 0:
    raise newException(TalkingHeadError,
      "synthesia provider: providerSettings.script_text is required " &
      "(Synthesia synthesises its own voice from text; the narration " &
      "WAV is not uploaded). Set " &
      "TalkingHeadOpts.providerSettings[\"script_text\"].")
  let avatar = resolveAvatar(opts)
  let background = resolveBackground(opts)
  let title = resolveTitle(opts)
  let test = resolveTest(opts)

  let device = effectiveDevice(opts)
  let cacheDir = effectiveCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  # `cacheKeyFor` insists both file paths exist. For Synthesia the
  # "avatar image" is conceptual (the avatar string is server-side),
  # so we alias narrationWav into both slots and fold the
  # Synthesia-specific knobs (script_text, avatar, background, title,
  # test) into the device slot via `synthesiaCacheSalt`. This keeps
  # two different script_text strings on the same WAV from colliding
  # in the cache.
  let salt = synthesiaCacheSalt(device, scriptText, avatar, background,
                                title, test)
  let key = cacheKeyFor(narrationWav, narrationWav, ProviderName, salt)

  let generator = proc() =
    let body = buildCreateVideoBody(scriptText, avatar, background, title,
                                    test)
    let videoId = createVideo(apiKey, apiBase, body)
    let videoUrl = pollVideoStatus(apiKey, apiBase, videoId,
                                   maxSecs = maxPollSecs,
                                   intervalMs = pollIntervalMs)
    downloadVideo(videoUrl, outputMp4)

  {.cast(gcsafe).}:
    discard applyCache(cacheDir, key, outputMp4, generator)

proc generateSynthesia*(narrationWav, outputMp4: string,
                       opts: TalkingHeadOpts) {.gcsafe.} =
  ## Production-defaults entry point. Tests that need fast polling can
  ## use `synthesiaProviderWithPolling` (below) to build a provider
  ## with a millisecond-interval poll, avoiding the 10-second
  ## production default.
  synthesiaGenerateImpl(narrationWav, outputMp4, opts,
                       DefaultMaxPollSecs, DefaultPollIntervalMs)

proc synthesiaProvider*(): TalkingHeadProvider =
  ## Build the Synthesia provider value with production polling
  ## defaults.
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: synthesiaIsAvailable,
    generate: generateSynthesia,
  )

proc synthesiaProviderWithPolling*(maxPollSecs: float,
                                  pollIntervalMs: int): TalkingHeadProvider =
  ## Variant for tests: lets the mock-server suite drive the full
  ## cycle without sleeping for seconds between polls. Production
  ## callers use `synthesiaProvider()`.
  let captured = (maxPollSecs, pollIntervalMs)
  let gen = proc(narrationWav, outputMp4: string,
                 opts: TalkingHeadOpts) {.gcsafe.} =
    {.cast(gcsafe).}:
      synthesiaGenerateImpl(narrationWav, outputMp4, opts,
                           captured[0], captured[1])
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: synthesiaIsAvailable,
    generate: gen,
  )

proc registerSynthesia*(r: TalkingHeadRegistry) =
  ## One-liner plugin entry point. Callers do:
  ##
  ## ```nim
  ## import gui_assert/talking_head
  ## import gui_assert_synthesia
  ##
  ## let reg = newRegistry()
  ## registerSynthesia(reg)
  ## generateTalkingHead(reg, "synthesia", wav, mp4, opts)
  ## ```
  r.registerProvider(synthesiaProvider())
