## Pure tests for Synthesia emotive translation + body mutation.

import std/[json, options, unittest]
import gui_assert/talking_head, gui_assert/emotive
import gui_assert_synthesia

suite "Synthesia emotiveToProviderSettings":

  test "green_screen background flows through to providerSettings":
    var c = initEmotive()
    c.background = some(bmGreenScreen)
    let j = emotiveToProviderSettings(c)
    check j["background"].getStr == "green_screen"

  test "solid_color writes a background_color when supplied":
    var c = initEmotive()
    c.background = some(bmSolidColor)
    c.backgroundColor = some("#123456")
    let j = emotiveToProviderSettings(c)
    check j["background_color"].getStr == "#123456"

  test "emotion + voice fields are dropped because backend ignores them":
    var c = initEmotive()
    c.emotion = some(eHappy)
    c.voiceSpeed = some(1.5)
    let j = emotiveToProviderSettings(c)
    check not j.hasKey("emotion")
    check not j.hasKey("voice_speed")

  test "caller-set base wins":
    var c = initEmotive()
    c.background = some(bmGreenScreen)
    let base = %*{"background": "white_studio"}
    let j = emotiveToProviderSettings(c, base)
    check j["background"].getStr == "white_studio"

suite "Synthesia applyBackgroundToBody":

  test "green_screen sets input[0].background to 'green_screen'":
    let body = buildCreateVideoBody("hello",
                                    DefaultSynthesiaAvatar,
                                    DefaultSynthesiaBackground,
                                    "title")
    var c = initEmotive()
    c.background = some(bmGreenScreen)
    applyBackgroundToBody(body, c)
    check body["input"][0]["background"].getStr == "green_screen"

  test "transparent maps to 'transparent'":
    let body = buildCreateVideoBody("hi", "anna_costume1_cameraA",
                                    "white_studio", "t")
    var c = initEmotive()
    c.background = some(bmTransparent)
    applyBackgroundToBody(body, c)
    check body["input"][0]["background"].getStr == "transparent"

  test "as_is leaves the original background untouched":
    let body = buildCreateVideoBody("hi", "anna_costume1_cameraA",
                                    "white_studio", "t")
    var c = initEmotive()
    c.background = some(bmAsIs)
    applyBackgroundToBody(body, c)
    check body["input"][0]["background"].getStr == "white_studio"

suite "Synthesia capabilities":

  test "self-describes the backend as text-input + green-screen":
    check SynthesiaCapabilities.supportsTextInput
    check SynthesiaCapabilities.supportsGreenScreen
    check not SynthesiaCapabilities.supportsAudioInput
    check not SynthesiaCapabilities.supportsEmotion
    check not SynthesiaCapabilities.supportsVoiceTuning
