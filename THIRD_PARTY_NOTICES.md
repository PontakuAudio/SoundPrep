# 第三者ライセンスと出典

SoundPrepは、以下の第三者コードを使用しています。SoundPrep独自部分の[MIT License](LICENSE)とは別に、それぞれのコードに元のライセンスが適用されます。この文書とリンク先のライセンスファイルは、ソースとReaPack配布物の両方に含めています。

## 一覧

| コード・ライブラリー | 使用箇所 | ライセンス・通知全文 |
|---|---|---|
| nlohmann/json 3.12.0 | Native helperのJSON処理 | [MIT](native/vendor/json.LICENSE.MIT) |
| nlohmann/json内のUTF-8 decoder・Grisu2・Hedley | 同ヘッダーに含まれるコード | [追加の著作権表示・MIT通知](native/vendor/json.THIRD_PARTY_NOTICES.md) |
| nlohmann/json内のAbseil由来コード | 同ヘッダーのC++11互換処理 | [Apache-2.0](native/vendor/abseil.LICENSE)・[追加通知](native/vendor/json.THIRD_PARTY_NOTICES.md) |
| MoSQITo 1.2.1由来の改変コード | 時間変動Zwickerラウドネス解析 | [Apache-2.0](native/vendor/mosqito.LICENSE.md) |
| libebur128 1.2.6由来の改変コード | K-weighting・True Peak補間 | [MIT](native/vendor/ebur128.LICENSE.MIT) |
| Cockos REAPER Plug-in APIの抜粋 | REAPERとの音声処理の接続 | [このページに掲載したCockosの通知](#cockos-reaper-plug-in-api) |

第三者コードを含むものを再配布する際は、対応する著作権表示とライセンス通知を保持し、各ライセンスの条件に従ってください。以下に出典と改変内容を記載します。

## nlohmann/json

- 出典: [nlohmann/json v3.12.0](https://github.com/nlohmann/json/releases/tag/v3.12.0)
- 著作権表示: Copyright (c) 2013-2025 Niels Lohmann
- ライセンス: [MIT全文](native/vendor/json.LICENSE.MIT)

macOS／WindowsのNative helperで、解析要求や結果などのJSONを扱うために使用しています。公開ソースの `native/vendor/json.hpp` は、上流のsingle-header版を変更せずに収録したものです。

同ヘッダーには以下の作者によるコード・通知も含まれます。

| コード | 著作権表示 |
|---|---|
| UTF-8 decoder | Copyright (c) 2008-2009 Björn Hoehrmann |
| Grisu2 | Copyright (c) 2009 Florian Loitsch |
| Hedley | Copyright (c) 2016-2021 Evan Nemerson |
| Abseil由来コード | Copyright 2017 The Abseil Authors、およびSPDXの2018年表記 |

原文の著作権表示とMIT通知は[追加通知](native/vendor/json.THIRD_PARTY_NOTICES.md)に保持しています。Hedleyの単体配布はCC0ですが、このヘッダー内のコピーに記載されたMIT通知を保持します。Abseil由来部分には[Apache-2.0全文](native/vendor/abseil.LICENSE)を同梱しています。SoundPrepのビルドはC++17ですが、配布するヘッダーにC++11用の処理も含まれるため、その通知も残しています。

## MoSQITo / time-varying Zwicker loudness

- 出典: [MoSQITo](https://github.com/Eomys/MoSQITo)、[参照した配布パッケージ1.2.1](https://pypi.org/project/mosqito/1.2.1/)
- 提供元: MoSQITo Developers
- ライセンス: [Apache License 2.0全文](native/vendor/mosqito.LICENSE.md)。参照パッケージの `LICENSE` を変更せずに収録しています。

Native helperの時間変動Zwickerカーネルは、MoSQITo 1.2.1由来の最適化Python実装をC++へ移植した改変版です。ライブラリー全体をそのまま組み込んだものではありません。対象となる処理は、1/3 octave filters、main loudness、nonlinear decay、critical-band slopes、temporal weightingです。

上流の `_main_loudness.py` は、E. Zwicker / H. FastlによるBASICプログラム（J.A.S.J. (E), 12(1), 1991）を基にすると記載し、ISO 532-1:2017の対応処理を挙げています。`_third_octave_levels.py` の係数には同規格のTable A.1 / A.2への参照があります。MoSQITo 1.2.1のwheelには独立したNOTICEファイルはありません。

**SoundPrepでの改変:** C++のdouble精度への移植、帯域powerの再利用、ゲイン候補の反復評価、固定長の作業領域、キャンセル対応、時間系列のMax／P95集計を行っています。呼出し側では校正、400 msの応答用末尾、チャンネル合成、メモリー上限を加えています。対応する開発ソースは `native/zwicker.cpp` と `native/zwicker.h` です。

移植元の最適化参照実装は `analyzer/fast_loudness.py`（SHA-256: `d8d524fb825f1eaa495dfb91cb8100427fd0467d9e983586b7cda4c4c8ddeebb`）です。最適化変更部分は本プロジェクトのメンテナーが作成しました。派生部分にはApache-2.0を適用し、SoundPrepのMIT Licenseで置き換えません。

## libebur128

- 出典: [libebur128 v1.2.6](https://github.com/jiixyj/libebur128/tree/v1.2.6)
- 著作権表示: Copyright (c) 2011 Jan Kokemüller
- ライセンス: [MIT全文](native/vendor/ebur128.LICENSE.MIT)。上流の `COPYING` を変更せずに収録しています。

Native helperのK-weightingとTrue Peak補間に、libebur128 v1.2.6を参照・改変したC++実装を使用しています。

**SoundPrepでの改変:** 400 ms窓／100 ms間隔のMax Momentary専用ストリーミング処理、dual-monoと独立チャンネルの扱い、C++の状態管理、異常値検査、ソースのサンプルレート別のTrue Peak補間を実装しています。対応する開発ソースは `native/lufs_meter.cpp` と `native/lufs_meter.h` です。ライブラリー全体や公開APIを同梱するものではなく、旧FFmpeg解析との数値の完全一致も保証しません。

## Cockos REAPER Plug-in API

出典: [Cockos REAPER SDK — reaper_plugin.h](https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h)

公開ソースの `native/reaper_audio_abi.h` は、`reaper_plugin.h` から音声ABI部分を抜粋した改変版です。macOS／Windows x64用の宣言を含みます。元のSDK全体ではありません。ソース内にも改変表示、出典、以下の通知を保持しています。

```text
REAPER Plug-in API

Copyright (C) 2006-2015, Cockos Incorporated

   This software is provided 'as-is', without any express or implied
   warranty.  In no event will the authors be held liable for any damages
   arising from the use of this software.

   Permission is granted to anyone to use this software for any purpose,
   including commercial applications, and to alter it and redistribute it
   freely, subject to the following restrictions:

   1. The origin of this software must not be misrepresented; you must not
      claim that you wrote the original software. If you use this software
      in a product, an acknowledgment in the product documentation would be
      appreciated but is not required.
   2. Altered source versions must be plainly marked as such, and must not be
      misrepresented as being the original software.
   3. This notice may not be removed or altered from any source distribution.

Notes: the C++ interfaces used require MSVC on win32, or at least the MSVC-compatible C++ ABI. Sorry, mingw users :(
```

## REAPER付属JSFXと別途導入するソフトウェア

既定のFX chainとモノ／ステレオ用の出力ゲインは、利用者のREAPER環境にある以下のJSFXを参照します。これらの実装コードはSoundPrepに同梱せず、それぞれの提供元のライセンスが適用されます。

- `filters/resonantlowpass`
- `loser/TransientController`
- `loser/Saturation`
- `utility/volume_pan`

同梱する `resources/audition_macro_channels_v1.jsfx`、`resources/audition_macro_channels_v2.jsfx`、`resources/audition_macro_channels_v3.jsfx` はSoundPrep独自のチャンネル変換・出力ゲイン用コードで、本プロジェクトのMIT Licenseの対象です。

REAPER、SWS、JS_ReaScriptAPI、ReaPackは、利用者が別途導入するソフトウェアです。各提供元の利用条件に従ってください。Python、FFmpeg／ffprobe、MoSQIToのインストールは通常利用には不要で、任意の開発用比較試験で使用する場合があります。SoundPrepのMIT Licenseは、これらのソフトウェアのライセンスを置き換えません。

## ソースと通知の収録範囲

解析エンジンはビルド済みNative helper内で配布しています。この文書に示す解析用ソースパスは開発環境での対応箇所であり、公開リポジトリにその実装が含まれることを意味しません。第三者コードのライセンス・改変表示は、バイナリ配布でも保持しています。詳しくは[ソースとバイナリの配布方針](docs/source-distribution.md)を参照してください。

[READMEに戻る](README.md) · [SoundPrepのMIT Licenseの案内](docs/license.md)
