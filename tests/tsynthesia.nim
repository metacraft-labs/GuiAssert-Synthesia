## Unit + integration tests for the Synthesia GuiAssert plugin.
##
## ## Pure tests (always run)
##
##   * `synthesiaAuthHeader` produces an `HttpHeaders` carrying the
##     documented raw-key `Authorization` value (no `Bearer ` prefix),
##   * `buildCreateVideoBody` emits the expected JSON shape (camelCase
##     `scriptText`, `input[]` array, top-level `title` + `test`),
##   * `resolveApiKey` honours providerSettings -> env-var precedence,
##   * `resolveApiBase` strips trailing slashes + defaults correctly,
##   * `resolveScriptText` / `resolveAvatar` / `resolveBackground` /
##     `resolveTitle` / `resolveTest` honour providerSettings,
##   * `synthesiaProvider()` is wired up with the canonical name + non-nil
##     callbacks,
##   * `registerSynthesia` integrates with the registry,
##   * `isAvailable()` reflects the presence of `SYNTHESIA_API_KEY`,
##   * cache-key determinism + per-input sensitivity (different
##     `script_text` / `avatar` / `background` -> different key).
##
## ## Mock-server integration test (always run, no network)
##
## A `std/asynchttpserver` mock spun up on a random free localhost
## port mirrors Synthesia's `POST /v2/videos` +
## `GET /v2/videos/{id}` + `GET /result.mp4` surface. The mock records
## every request (method, path, headers, body) so the test can then
## assert — by exact value — that the provider sent the raw
## `Authorization` header and the JSON body shape Synthesia expects.
## The mock returns a small ffmpeg-generated MP4 as the "render
## result"; the test then verifies the provider's downloaded file
## matches the mock's file byte-for-byte, and that a second invocation
## hits the on-disk cache and skips all HTTP.
##
## ## Live test (compile-time-gated via `-d:synthesiaLive`)
##
##   nim c -d:synthesiaLive -r --threads:on --hints:off \
##       --path:src --path:../GuiAssert/src tests/tsynthesia.nim
##
## Requires `SYNTHESIA_API_KEY` to be set. Per project policy, the
## live suite never silently skips: a missing key is a test failure.

import std/[asynchttpserver, asyncdispatch, httpcore, json,
            net, options, os, osproc, streams, strformat, strutils,
            tables, times, unittest]

import gui_assert/talking_head
import gui_assert_synthesia

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

proc thisRepoRoot(): string =
  ## `currentSourcePath` -> .../GuiAssert-Synthesia/tests/tsynthesia.nim
  currentSourcePath().parentDir().parentDir()

# ---------------------------------------------------------------------------
# Fixture synthesis (also used by the mock server's result MP4).
# ---------------------------------------------------------------------------

proc runSh(args: openArray[string]): tuple[code: int, output: string] =
  let bin = findExe(args[0])
  doAssert bin.len > 0, "binary not on PATH: " & args[0]
  var rest: seq[string] = @[]
  for i in 1 ..< args.len: rest.add args[i]
  let p = startProcess(
    command = bin, args = rest, options = {poStdErrToStdOut}
  )
  let raw = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  result = (code: code, output: raw)

proc bundledNarration(): string =
  let p = thisRepoRoot() / "tests" / "fixtures" / "narration.wav"
  doAssert fileExists(p), "missing narration fixture: " & p
  p

proc ensureMockMp4(): string =
  ## Produce a small testsrc MP4 (~3 s, ~30 KB) that the mock server
  ## serves as the `download` payload. Synthesised once per test run
  ## under /tmp to keep the repo clean.
  let target = "/tmp/tsynthesia-mock-result.mp4"
  if fileExists(target) and getFileSize(target) > 5_000:
    return target
  let ffBin =
    block:
      let env = getEnv("FFMPEG_BIN")
      if env.len > 0 and fileExists(env): env
      else: findExe("ffmpeg")
  doAssert ffBin.len > 0, "ffmpeg missing on PATH; needed by the mock server"
  if fileExists(target): removeFile(target)
  let r = runSh([ffBin, "-hide_banner", "-loglevel", "error", "-y",
                 "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                 "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "64k", "-shortest", target])
  doAssert r.code == 0, "ffmpeg mock MP4 synthesis failed: " & r.output
  result = target

# ---------------------------------------------------------------------------
# Pure tests
# ---------------------------------------------------------------------------

suite "synthesia auth header":

  test "produces an Authorization header carrying the raw key (no Bearer prefix)":
    let h = synthesiaAuthHeader("foo")
    check h.hasKey("Authorization")
    check h["Authorization"] == "foo"

  test "pins Content-Type: application/json alongside":
    let h = synthesiaAuthHeader("DUMMY_KEY")
    check h["Authorization"] == "DUMMY_KEY"
    check h["Content-Type"] == "application/json"

  test "does not prepend Bearer or Basic to the key":
    # Synthesia's quirky scheme: the Authorization header carries the
    # RAW key, not a Bearer token and not HTTP Basic auth. Regression
    # guard: future "fixes" that wrap the key in a prefix must not
    # land silently.
    let h = synthesiaAuthHeader("api-key-xyz")
    check h["Authorization"] == "api-key-xyz"
    check (not h["Authorization"].startsWith("Bearer "))
    check (not h["Authorization"].startsWith("Basic "))

  test "does not include any X-Api-Key header":
    # Synthesia uses `Authorization`, NOT `X-Api-Key` like the sibling
    # HeyGen plugin. Regression guard against a copy-paste from
    # HeyGen.
    let h = synthesiaAuthHeader("any-key")
    check (not h.hasKey("X-Api-Key"))

suite "synthesia create-video body":

  test "builds the documented v2 JSON shape":
    let body = buildCreateVideoBody("Hello, this is Synthesia.",
                                    "anna_costume1_cameraA",
                                    "white_studio",
                                    "Test video")
    check body.kind == JObject
    # test defaults to true (sandbox / no-quota render)
    check body["test"].getBool == true
    let input = body["input"]
    check input.kind == JArray
    check input.len == 1
    let entry = input[0]
    # scriptText must be camelCase, not snake_case — Synthesia is
    # quirky here vs. the rest of the API ecosystem.
    check entry["scriptText"].getStr == "Hello, this is Synthesia."
    check entry["avatar"].getStr == "anna_costume1_cameraA"
    check entry["background"].getStr == "white_studio"
    check body["title"].getStr == "Test video"

  test "honours explicit test=false":
    let body = buildCreateVideoBody("hi", "anna_costume1_cameraA",
                                    "white_studio", "Live render",
                                    test = false)
    check body["test"].getBool == false
    check body["title"].getStr == "Live render"
    check body["input"][0]["scriptText"].getStr == "hi"

  test "scriptText is camelCase, not snake_case":
    # Regression guard: the rest of the ecosystem uses snake_case
    # (script_text, avatar_id, voice_id). Synthesia documents
    # camelCase scriptText specifically — this guards against a
    # silent rename to script_text.
    let body = buildCreateVideoBody("x", "y", "z", "t")
    check body["input"][0].hasKey("scriptText")
    check (not body["input"][0].hasKey("script_text"))

suite "synthesia opts resolution":

  test "resolveApiKey prefers providerSettings over env":
    putEnv(ApiKeyEnvVar, "ENV_KEY")
    let opts = TalkingHeadOpts(
      providerSettings: %*{"api_key": "OPTS_KEY"}
    )
    check resolveApiKey(opts) == "OPTS_KEY"
    delEnv(ApiKeyEnvVar)

  test "resolveApiKey falls back to env when providerSettings empty":
    putEnv(ApiKeyEnvVar, "ENV_ONLY")
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiKey(opts) == "ENV_ONLY"
    delEnv(ApiKeyEnvVar)

  test "resolveApiKey returns empty when neither set":
    delEnv(ApiKeyEnvVar)
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiKey(opts) == ""

  test "resolveApiBase strips trailing slashes":
    let opts = TalkingHeadOpts(
      providerSettings: %*{"api_base": "http://x.test:9000///"}
    )
    check resolveApiBase(opts) == "http://x.test:9000"

  test "resolveApiBase defaults to the public Synthesia endpoint":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiBase(opts) == DefaultSynthesiaApiBase
    check DefaultSynthesiaApiBase == "https://api.synthesia.io"

  test "resolveScriptText reads providerSettings.script_text":
    let opts = TalkingHeadOpts(
      providerSettings: %*{"script_text": "Hello world."}
    )
    check resolveScriptText(opts) == "Hello world."

  test "resolveScriptText returns empty when missing":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveScriptText(opts) == ""

  test "resolveAvatar / resolveBackground default to documented IDs":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveAvatar(opts) == DefaultSynthesiaAvatar
    check resolveBackground(opts) == DefaultSynthesiaBackground
    check DefaultSynthesiaAvatar == "anna_costume1_cameraA"
    check DefaultSynthesiaBackground == "white_studio"

  test "resolveAvatar / resolveBackground read providerSettings overrides":
    let opts = TalkingHeadOpts(
      providerSettings: %*{
        "avatar": "custom_avatar_42",
        "background": "office_neutral"
      }
    )
    check resolveAvatar(opts) == "custom_avatar_42"
    check resolveBackground(opts) == "office_neutral"

  test "resolveTitle defaults / overrides":
    check resolveTitle(TalkingHeadOpts(providerSettings: newJObject())) ==
      DefaultTitle
    let opts = TalkingHeadOpts(
      providerSettings: %*{"title": "Custom Title"}
    )
    check resolveTitle(opts) == "Custom Title"

  test "resolveTest defaults to true (sandbox)":
    check resolveTest(TalkingHeadOpts(providerSettings: newJObject())) == true

  test "resolveTest reads bool or string from providerSettings":
    let optsBool = TalkingHeadOpts(providerSettings: %*{"test": false})
    check resolveTest(optsBool) == false
    let optsStr = TalkingHeadOpts(providerSettings: %*{"test": "false"})
    check resolveTest(optsStr) == false
    let optsYes = TalkingHeadOpts(providerSettings: %*{"test": "yes"})
    check resolveTest(optsYes) == true

suite "synthesia provider value":

  test "synthesiaProvider builds a provider with the canonical name":
    let p = synthesiaProvider()
    check p.name == ProviderName
    check p.name == "synthesia"
    check (not p.isAvailable.isNil)
    check (not p.generate.isNil)

  test "registerSynthesia exposes the plugin via the registry":
    let r = newRegistry()
    check (not hasProvider(r, "synthesia"))
    registerSynthesia(r)
    check hasProvider(r, "synthesia")
    let got = getProvider(r, "synthesia")
    check got.name == "synthesia"
    # Built-in stock_avatar must remain registered.
    check hasProvider(r, "stock_avatar")

suite "synthesia isAvailable":

  test "returns false when SYNTHESIA_API_KEY is unset":
    delEnv(ApiKeyEnvVar)
    check (not synthesiaIsAvailable())

  test "returns true when SYNTHESIA_API_KEY is set":
    putEnv(ApiKeyEnvVar, "anything-nonempty")
    check synthesiaIsAvailable()
    delEnv(ApiKeyEnvVar)

suite "synthesia cache key":

  setup:
    let cacheTmp = getTempDir() / "tsynthesia_cachekey"
    if dirExists(cacheTmp): removeDir(cacheTmp)
    createDir(cacheTmp)
    let nar1 = cacheTmp / "n1.wav"
    let nar2 = cacheTmp / "n2.wav"
    writeFile(nar1, "RIFF-A")
    writeFile(nar2, "RIFF-B")

  test "same inputs (same salt) produce the same key":
    let salt = synthesiaCacheSalt("auto", "hello", DefaultSynthesiaAvatar,
                                  DefaultSynthesiaBackground,
                                  DefaultTitle, true)
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, salt)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, salt)
    check k1 == k2
    check k1.len == 16

  test "different narration WAV -> different key":
    let salt = synthesiaCacheSalt("auto", "hello", DefaultSynthesiaAvatar,
                                  DefaultSynthesiaBackground,
                                  DefaultTitle, true)
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, salt)
    let k2 = cacheKeyFor(nar2, nar2, ProviderName, salt)
    check k1 != k2

  test "different script_text -> different cache-salt -> different key":
    let saltA = synthesiaCacheSalt("auto", "Hello.", DefaultSynthesiaAvatar,
                                   DefaultSynthesiaBackground,
                                   DefaultTitle, true)
    let saltB = synthesiaCacheSalt("auto", "Goodbye.", DefaultSynthesiaAvatar,
                                   DefaultSynthesiaBackground,
                                   DefaultTitle, true)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

  test "different avatar -> different cache-salt -> different key":
    let saltA = synthesiaCacheSalt("auto", "hello", "avatar_A",
                                   DefaultSynthesiaBackground,
                                   DefaultTitle, true)
    let saltB = synthesiaCacheSalt("auto", "hello", "avatar_B",
                                   DefaultSynthesiaBackground,
                                   DefaultTitle, true)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

  test "different background -> different cache-salt -> different key":
    let saltA = synthesiaCacheSalt("auto", "hello", DefaultSynthesiaAvatar,
                                   "bg_A", DefaultTitle, true)
    let saltB = synthesiaCacheSalt("auto", "hello", DefaultSynthesiaAvatar,
                                   "bg_B", DefaultTitle, true)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

  test "different test flag -> different cache-salt -> different key":
    let saltA = synthesiaCacheSalt("auto", "hello", DefaultSynthesiaAvatar,
                                   DefaultSynthesiaBackground,
                                   DefaultTitle, true)
    let saltB = synthesiaCacheSalt("auto", "hello", DefaultSynthesiaAvatar,
                                   DefaultSynthesiaBackground,
                                   DefaultTitle, false)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

suite "synthesia generate input validation":

  test "missing API key raises TalkingHeadError at generate time":
    delEnv(ApiKeyEnvVar)
    let p = synthesiaProvider()
    let tmp = getTempDir() / "tsynthesia_no_key"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeFile(nar, "RIFF")
    let outMp4 = tmp / "out.mp4"
    let opts = TalkingHeadOpts(
      cacheDir: some(tmp / "cache"),
      providerSettings: %*{"script_text": "hi"},
    )
    expect TalkingHeadError:
      p.generate(nar, outMp4, opts)

  test "missing script_text raises TalkingHeadError at generate time":
    putEnv(ApiKeyEnvVar, "DUMMY")
    try:
      let p = synthesiaProvider()
      let tmp = getTempDir() / "tsynthesia_no_script"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)
      let nar = tmp / "n.wav"
      writeFile(nar, "RIFF")
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(
        cacheDir: some(tmp / "cache"),
        providerSettings: newJObject(),
      )
      expect TalkingHeadError:
        p.generate(nar, outMp4, opts)
    finally:
      delEnv(ApiKeyEnvVar)

  test "missing narration WAV raises TalkingHeadError":
    putEnv(ApiKeyEnvVar, "DUMMY")
    try:
      let p = synthesiaProvider()
      let tmp = getTempDir() / "tsynthesia_no_wav"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(
        cacheDir: some(tmp / "cache"),
        providerSettings: %*{"script_text": "hi"},
      )
      expect TalkingHeadError:
        p.generate(tmp / "does-not-exist.wav", outMp4, opts)
    finally:
      delEnv(ApiKeyEnvVar)

# ---------------------------------------------------------------------------
# Mock-server integration test (no network).
# ---------------------------------------------------------------------------

type
  RecordedRequest = object
    httpMethod: string
    path: string
    query: string
    authHeader: string
    contentType: string
    body: string

# Shared global state for the mock server. asynchttpserver's request
# handler is a `proc(req): Future[void]`, which can't easily close
# over per-test locals when we're also pinning -d:taintMode. Globals
# in test code are the path of least resistance.
var mockRequests: seq[RecordedRequest]
var mockResultMp4Path: string
var mockPollCount: int
var mockPollsBeforeDone: int
var mockServerPort: int

proc firstHeader(h: HttpHeaders, name: string): string =
  if h.hasKey(name):
    let vals = h.table[name.toLowerAscii]
    if vals.len > 0: return vals[0]
  return ""

proc mockHandler(req: Request): Future[void] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    var rec = RecordedRequest(
      httpMethod: $req.reqMethod,
      path: req.url.path,
      query: req.url.query,
      authHeader: firstHeader(req.headers, "authorization"),
      contentType: firstHeader(req.headers, "content-type"),
      body: req.body,
    )
    mockRequests.add rec

    let m = req.reqMethod
    let p = req.url.path
    let portStr = $mockServerPort

    if m == HttpPost and p == "/v2/videos":
      let payload = %*{
        "id": "vid_TEST",
        "status": "in_progress"
      }
      await req.respond(Http201, $payload,
                        newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpGet and p.startsWith("/v2/videos/"):
      mockPollCount.inc
      let videoId = p["/v2/videos/".len .. ^1]
      if mockPollCount <= mockPollsBeforeDone:
        let payload = %*{
          "id": videoId,
          "status": "in_progress"
        }
        await req.respond(Http200, $payload,
                          newHttpHeaders({"Content-Type": "application/json"}))
      else:
        let payload = %*{
          "id": videoId,
          "status": "complete",
          "download": "http://localhost:" & portStr & "/result.mp4"
        }
        await req.respond(Http200, $payload,
                          newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpGet and p == "/result.mp4":
      let bytes = readFile(mockResultMp4Path)
      await req.respond(Http200, bytes,
                        newHttpHeaders({"Content-Type": "video/mp4"}))
      return

    await req.respond(Http404, "mock: no route for " & $m & " " & p,
                      newHttpHeaders({"Content-Type": "text/plain"}))

proc pickFreePort(): int =
  ## Bind to port 0 to let the OS allocate a free port, then close
  ## the socket and reuse the number. There's a tiny race window
  ## before the asynchttpserver claims the port, but it's good enough
  ## for a single-test-run mock and avoids hardcoding ports that
  ## might collide on CI.
  let s = newSocket()
  s.bindAddr(Port(0))
  let (_, port) = s.getLocalAddr
  s.close()
  result = int(port)

var mockServerThread: Thread[int]
var mockServerStopFlag: bool

proc mockServerThreadProc(port: int) {.thread.} =
  {.cast(gcsafe).}:
    let server = newAsyncHttpServer()
    asyncCheck server.serve(Port(port), mockHandler, address = "127.0.0.1")
    while not mockServerStopFlag:
      # Drive the asyncdispatch loop on this dedicated thread so the
      # main thread can issue blocking httpclient calls.
      poll(50)
    server.close()

proc startMockServer(): tuple[port: int, stop: proc() {.gcsafe.}] =
  let port = pickFreePort()
  mockServerPort = port
  mockRequests = @[]
  mockPollCount = 0
  mockServerStopFlag = false
  createThread(mockServerThread, mockServerThreadProc, port)
  # Give the server thread a moment to bind + start serving before we
  # let the caller fire requests at it.
  sleep(150)
  let stop = proc() {.gcsafe.} =
    mockServerStopFlag = true
    joinThread(mockServerThread)
  result = (port: port, stop: stop)

suite "synthesia mock-server integration":

  test "creates + polls + downloads through a local mock and caches the result":
    let narration = bundledNarration()
    let resultMp4 = ensureMockMp4()
    mockResultMp4Path = resultMp4
    mockPollsBeforeDone = 2  # /v2/videos/{id} returns in_progress twice

    let (port, stop) = startMockServer()
    defer: stop()

    let portStr = $port
    echo &"  mock server listening on http://localhost:{portStr}"

    # Provider with millisecond polling so the test runs fast.
    let provider = synthesiaProviderWithPolling(maxPollSecs = 30.0,
                                                pollIntervalMs = 50)

    let tmp = getTempDir() / "tsynthesia_mock"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let outMp4 = tmp / "synthesia-mock.mp4"
    let opts = TalkingHeadOpts(
      device: "auto",
      cacheDir: some(tmp / "cache"),
      providerSettings: %*{
        "api_base": "http://localhost:" & portStr,
        "api_key": "DUMMY_KEY",
        "script_text": "Hello from GuiAssert Synthesia mock test.",
        "avatar": "anna_costume1_cameraA",
        "background": "white_studio",
        "title": "GuiAssert mock render",
        "test": true,
      },
    )

    let started = epochTime()
    provider.generate(narration, outMp4, opts)
    let dt = epochTime() - started
    echo &"  full mock round-trip took {dt*1000:.1f} ms"

    # ----- Recorded-request trace -----
    echo "  recorded requests (", $mockRequests.len, "):"
    for i, r in mockRequests:
      let bodyPreview =
        if r.body.len <= 240: r.body
        else: r.body[0 ..< 240] & " ...(+" & $(r.body.len - 240) & " bytes)"
      echo &"    [{i}] {r.httpMethod} {r.path} ?{r.query}"
      echo &"        Authorization: {r.authHeader}"
      echo &"        Content-Type: {r.contentType}"
      echo &"        body[{r.body.len}]: {bodyPreview}"

    # ----- Assertion checks -----
    # With mockPollsBeforeDone=2 the trace is:
    #   [0] POST /v2/videos
    #   [1] GET  /v2/videos/vid_TEST  (status=in_progress)
    #   [2] GET  /v2/videos/vid_TEST  (status=in_progress)
    #   [3] GET  /v2/videos/vid_TEST  (status=complete)
    #   [4] GET  /result.mp4
    check mockRequests.len == 5

    check mockRequests[0].httpMethod == "POST"
    check mockRequests[0].path == "/v2/videos"
    check mockRequests[1].httpMethod == "GET"
    check mockRequests[1].path == "/v2/videos/vid_TEST"
    check mockRequests[2].httpMethod == "GET"
    check mockRequests[2].path == "/v2/videos/vid_TEST"
    check mockRequests[3].httpMethod == "GET"
    check mockRequests[3].path == "/v2/videos/vid_TEST"
    check mockRequests[4].httpMethod == "GET"
    check mockRequests[4].path == "/result.mp4"

    # ----- Authorization header exact-string check on every API request -----
    # The /result.mp4 download is served from the CDN and the plugin
    # intentionally does NOT send the auth header for it. Validate
    # that distinction here.
    for i in 0..3:
      check mockRequests[i].authHeader == "DUMMY_KEY"
    check mockRequests[4].authHeader == ""

    # ----- POST /v2/videos JSON body shape -----
    check mockRequests[0].contentType == "application/json"
    let createBody = parseJson(mockRequests[0].body)
    check createBody.kind == JObject
    check createBody["test"].getBool == true
    check createBody["title"].getStr == "GuiAssert mock render"
    let input = createBody["input"]
    check input.kind == JArray
    check input.len == 1
    let entry = input[0]
    # camelCase scriptText — regression guard against silent
    # snake_case "fix".
    check entry["scriptText"].getStr ==
      "Hello from GuiAssert Synthesia mock test."
    check entry["avatar"].getStr == "anna_costume1_cameraA"
    check entry["background"].getStr == "white_studio"
    check (not entry.hasKey("script_text"))

    # ----- Poll GETs have empty body -----
    for i in 1..3:
      check mockRequests[i].body.len == 0

    # ----- Polling cadence respected: 3 polls happened (2 in_progress + 1 complete) -----
    check mockPollCount == 3
    # And the wall-clock should be at least 2 * intervalMs (50 ms) =
    # 100 ms, evidencing that the polling loop did NOT short-circuit.
    check dt >= 0.100

    # ----- Download produced a byte-identical MP4 -----
    check fileExists(outMp4)
    let downloaded = readFile(outMp4)
    let golden = readFile(resultMp4)
    check downloaded.len == golden.len
    check downloaded == golden
    echo &"  downloaded MP4 = {downloaded.len} bytes; matches mock-served golden"

    # ----- Cache hit on the second invocation skips all HTTP -----
    let beforeCount = mockRequests.len
    let outMp4_2 = tmp / "synthesia-mock-2.mp4"
    let secondStart = epochTime()
    provider.generate(narration, outMp4_2, opts)
    let secondDt = epochTime() - secondStart
    echo &"  cache-hit second call took {secondDt*1000:.1f} ms"
    check mockRequests.len == beforeCount  # no new HTTP traffic
    check fileExists(outMp4_2)
    check getFileSize(outMp4_2) == golden.len
    check readFile(outMp4_2) == golden

    # ----- Cache miss when script_text changes -----
    let outMp4_3 = tmp / "synthesia-mock-3.mp4"
    var optsDifferent = opts
    optsDifferent.providerSettings = %*{
      "api_base": "http://localhost:" & portStr,
      "api_key": "DUMMY_KEY",
      "script_text": "A completely different script.",
      "avatar": "anna_costume1_cameraA",
      "background": "white_studio",
      "title": "GuiAssert mock render",
      "test": true,
    }
    mockPollCount = 0  # reset so the third invocation polls again
    provider.generate(narration, outMp4_3, optsDifferent)
    # New script_text -> different cache key -> 5 fresh requests
    # (POST + 3 status polls + result download).
    check mockRequests.len == beforeCount + 5
    check fileExists(outMp4_3)
    # The mock always returns the same MP4, but the cache entry is
    # NEW: a separate file in the cache dir with a different name.
    let createBody2 = parseJson(mockRequests[beforeCount].body)
    check createBody2["input"][0]["scriptText"].getStr ==
      "A completely different script."

# ---------------------------------------------------------------------------
# Live test — compile-time-gated. Real Synthesia API.
# ---------------------------------------------------------------------------
when defined(synthesiaLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffprobe =
      block:
        let env = getEnv("FFPROBE_BIN")
        if env.len > 0 and fileExists(env): env
        else: findExe("ffprobe")
    doAssert ffprobe.len > 0 and fileExists(ffprobe),
      "ffprobe not on PATH; install ffmpeg to run the live Synthesia test."
    let p = startProcess(
      command = ffprobe,
      args = @["-hide_banner", "-v", "error", "-print_format", "json",
               "-show_streams", "-show_format", path],
      options = {poStdErrToStdOut}
    )
    let raw = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "ffprobe failed (" & $code & "): " & raw
    parseJson(raw)

  proc ensureLiveNarration(): string =
    let envOverride = getEnv("GUI_ASSERT_SYNTHESIA_TEST_WAV")
    if envOverride.len > 0:
      doAssert fileExists(envOverride),
        "GUI_ASSERT_SYNTHESIA_TEST_WAV points at a non-existent path: " &
        envOverride
      return envOverride
    let bundled = thisRepoRoot() / "tests" / "fixtures" / "narration.wav"
    doAssert fileExists(bundled),
      "no narration fixture at " & bundled &
      " (set GUI_ASSERT_SYNTHESIA_TEST_WAV to override)"
    result = bundled

  suite "synthesia live render against api.synthesia.io":

    test "renders a real talking-head MP4 via the Synthesia API":
      doAssert getEnv(ApiKeyEnvVar).len > 0,
        "SYNTHESIA_API_KEY is not set. Live Synthesia tests require a " &
        "real API key from https://app.synthesia.io (Creator+ plan; " &
        "API access typically gated to Creator/Enterprise tiers — " &
        "Starter $29/mo, Creator $89/mo, Enterprise custom). Export " &
        "SYNTHESIA_API_KEY=<your key> and re-run with -d:synthesiaLive."

      let narration = ensureLiveNarration()

      let tmp = getTempDir() / "tsynthesia_live"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)

      let r = newRegistry()
      registerSynthesia(r)

      let outMp4 = tmp / "live.mp4"
      let opts = TalkingHeadOpts(
        device: "auto",
        cacheDir: some(tmp / "cache"),
        providerSettings: %*{
          "script_text": "Hello GuiAssert Synthesia",
          "avatar": DefaultSynthesiaAvatar,
          "background": DefaultSynthesiaBackground,
          "title": "GuiAssert live test",
          # Sandbox render: watermarked, does not deduct from quota.
          "test": true,
        },
        extraArgs: @[],
      )

      let started = epochTime()
      generateTalkingHead(r, "synthesia", narration, outMp4, opts)
      let dt = epochTime() - started
      echo &"  live Synthesia render took {dt:.1f}s"

      doAssert fileExists(outMp4), "no MP4 at " & outMp4
      let sz = getFileSize(outMp4)
      echo &"  output: {sz} bytes"
      check sz > 50_000

      let probe = ffprobeJson(outMp4)
      var hasVideo = false
      var hasAudio = false
      for s in probe{"streams"}.items:
        let kind = s{"codec_type"}.getStr()
        if kind == "video": hasVideo = true
        elif kind == "audio": hasAudio = true
      check hasVideo
      check hasAudio

      let videoDur = parseFloat(probe{"format", "duration"}.getStr())
      echo &"  talking-head dur: {videoDur:.3f}s"
      check videoDur > 1.0

      # Cache hit — second call must be near-instant.
      let secondStart = epochTime()
      let outMp4_2 = tmp / "live2.mp4"
      generateTalkingHead(r, "synthesia", narration, outMp4_2, opts)
      let secondDt = epochTime() - secondStart
      echo &"  second call (cache hit) took {secondDt:.3f}s"
      check secondDt < 5.0
      check fileExists(outMp4_2)
      check getFileSize(outMp4_2) == getFileSize(outMp4)
