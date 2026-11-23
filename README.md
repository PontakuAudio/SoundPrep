# SoundPrep

SoundPrep is a Media Explorer extension script for sound designers.

You can preview audio files through an effect chain and switch effect presets in real time while you listen. When you take a sound to the timeline, its settings are applied to the item, and rendered automatically when they need to be baked in.

With multichannel material, you can play back only the channels you choose, or preview with a downmix. Ambisonics material is previewed with a simple downmix.

Key Features

- Preview audio through an effect chain
- Save Media Explorer parameters like Playback Rate and Pitch as presets
- Switch presets in real time while listening to a single sound
- When you take a selection to the timeline, all of its settings are applied to the item, rendered automatically when they need to be baked in
- Measure loudness and preview at any LUFS you choose
- For multi-microphone recordings, preview only the channels you pick
- For multichannel material, preview with a downmix

Download & Installation

Register the URL below in ReaPack via Import repositories, then install SoundPrep.

https://github.com/PontakuAudio/reapack/raw/main/index.xml

After installing, run SoundPrep.lua from REAPER's Action List to start it. SWS Extension, JS_ReaScriptAPI and ReaPack are required first. See the install guide (https://github.com/PontakuAudio/SoundPrep/blob/main/docs/install.md) for details.

Only the launch action is registered automatically. If you need the extra key and diagnostic actions, run the bundled `SoundPrep - Install actions.lua` once.

Works with REAPER 7.35 or later, on macOS or Windows (REAPER x64).

SoundPrep is free. If it saves you time, you can support its development on Ko-fi: https://ko-fi.com/kuma_pontakuaudio
