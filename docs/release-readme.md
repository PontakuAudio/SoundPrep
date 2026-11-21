# SoundPrep

REAPER Media Explorer用のサウンドデザイン向け拡張スクリプトです。Windows / macOSに対応しています。

**使用時に `SoundPrep.lua` をRunしてください。** 起動後はMedia Explorerに表示される操作バーを使います。

0.11.12では、Media Explorerで素材を探すときのCPU負荷を軽減しました。新規インストールでは、挿入時に選択範囲だけをレンダーし、処理を伴う未キャッシュのドロップは編集可能なSource + FXとして即座に配置します。[変更点と更新手順（英語）](docs/releases/0.11.12.md)

## ReaPackから導入

必要環境: REAPER 7.35以降、SWS、JS_ReaScriptAPI、ReaPack。Windowsは10/11のx64版が対象です。

1. `Extensions → ReaPack → Import repositories…` に次のURLを追加します。

   ```text
   https://github.com/PontakuAudio/reapack/raw/main/index.xml
   ```

2. `Browse packages…` で **SoundPrep** を検索してInstallします。
3. REAPERを再起動し、Main Action Listから `SoundPrep.lua` を実行します。

Native helperが同時にインストールされます。同じSoundPrepパッケージの更新はReaPackから行います。

新規導入時に自動登録するActionは起動用の1個です。キー操作・診断用Actionsが必要な場合だけ、同梱の `SoundPrep - Install actions.lua` を読み込んで実行します。通常の起動には不要です。既存のAction登録・キー割当は自動削除しません。

## サポート

SoundPrep は無料で公開しています。役に立ったら、Ko-fi で開発の支援をいただけると助かります。

https://ko-fi.com/kuma_pontakuaudio

[詳しい導入手順](docs/install.md) · [MIT License](docs/license.md) · [第三者ライセンス](THIRD_PARTY_NOTICES.md)
