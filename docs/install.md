# SoundPrepの導入手順

SoundPrepはReaPackからインストールします。**起動するには `SoundPrep.lua` を実行してください。** 起動後は、Media Explorerに表示される操作バーを使います。

## 1. 必要な環境を準備する

| 項目 | 対応・入手先 |
|---|---|
| REAPER | [REAPER 7.35以降](https://www.reaper.fm/download.php) |
| Windows | Windows 10 / 11、REAPER x64版 |
| macOS | Apple Silicon / Intel |
| SWS Extension | [公式サイト](https://www.sws-extension.org/)から、使用するREAPERに合う版を導入 |
| ReaPack | [公式サイト](https://reapack.com/)の案内に従って導入 |
| JS_ReaScriptAPI | ReaPackから導入（下記参照） |

SWSとReaPackを導入したら、作業を保存してREAPERを再起動します。メニューバーに `Extensions → ReaPack` があることを確認してください。

### JS_ReaScriptAPIを導入する

1. `Extensions → ReaPack → Browse packages…` を開きます。
2. `js_ReaScriptAPI` を検索し、該当する拡張パッケージを右クリックして `Install` を選びます。
3. `Apply` を押してインストールし、作業を保存してREAPERを再起動します。

見つからない場合は、`Extensions → ReaPack → Import repositories…` で次のURLを追加してから、もう一度検索してください。

```text
https://raw.githubusercontent.com/ReaTeam/Extensions/master/index.xml
```

詳しくは[JS_ReaScriptAPIの配布元](https://github.com/juliansader/ReaExtensions)を参照してください。すでに導入済みなら、この作業は不要です。

## 2. SoundPrepをインストールする

1. `Extensions → ReaPack → Import repositories…` を開き、次のURLを追加します。

   ```text
   https://github.com/PontakuAudio/SoundPrep/releases/latest/download/index.xml
   ```

2. `Extensions → ReaPack → Browse packages…` を開き、`SoundPrep` を検索します。
3. SoundPrepのパッケージを右クリックし、`Install` を選んで `Apply` を押します。
4. インストールが完了したら、作業を保存してREAPERを再起動します。これでNative helperが読み込まれます。

パッケージ内のLua・リソース・ライセンス類は一緒に配置されます。Luaファイルが複数あっても、個別に登録・実行する必要はありません。

## 3. SoundPrepを起動する

1. REAPERの `Actions → Show action list…` を開きます。
2. `Section` を **Main** にして、`SoundPrep.lua` を検索します。
3. `Script: SoundPrep.lua` を選び、**Run** を押します。
4. Media Explorerに操作バーが表示されたら起動完了です。音声ファイルを選んで試聴してください。

次回以降も同じActionから起動します。よく使う場合は、このActionにショートカットを割り当てられます。SoundPrepを終了するには、SoundPrepの `Quit` を使います。

新規導入時に自動登録されるActionは、この起動用の1個です。内部処理用の `lib/` や `internal/` にあるLuaは読み込まないでください。

## 更新する

1. 実行中のSoundPrepを `Quit` で終了します。
2. `Extensions → ReaPack → Synchronize packages` で更新します。
3. Native helperの更新や再起動の案内がある場合は、作業を保存してREAPERを再起動します。
4. Main Action Listから `SoundPrep.lua` を実行します。

設定や保存したPresetは、インストール先の `data/` に保存されます。このフォルダーは削除せず、必要に応じてバックアップしてください。

0.11.10ではWindows・macOSともにNative helperを更新します。更新後はREAPERを完全に終了して再起動してください。本体とhelperはReaPackから一緒に導入されます。

## 追加Actions（任意）

起動後の操作はSoundPrepの画面から行えます。Play / StopやPreset切替などに専用キーを割り当てたい場合だけ、追加Actionsを登録してください。

1. `Options → Show REAPER resource path in explorer/finder` で、使用中のREAPERのResource Pathを開きます。
2. `Scripts/SoundPrep/Media Explorer/` フォルダーを開きます。
3. REAPERのMain Action Listで `New action → Load ReaScript` を選び、その中の **`SoundPrep - Install actions.lua`** を読み込んで実行します。
4. Action Listの `Section` を切り替えて、必要なActionにキーを割り当てます。

| Section | 登録される追加Actions |
|---|---|
| Media Explorer | Slot 0〜9、Play Stop、Replay、Stop、Reverse、AB、Analyse、Export、Edit、Quit |
| Main | Diagnostics、Restore native preview、Render selected drops、Restore selected source FX、Offline inactive source FX |

追加Actionsの登録後も、起動するのは `SoundPrep.lua` です。必要なLuaだけを、それぞれのSectionで個別に読み込むこともできます。

以前の版で登録したActionやキー割当は、自動削除しません。不要になったものはAction Listから手動で登録解除できます。パッケージ内のスクリプトファイル自体は削除しないでください。

## うまく起動しないとき

| 症状 | 確認すること |
|---|---|
| ReaPackメニューがない | ReaPackが使用中のREAPERへ導入されているか確認し、REAPERを再起動します。Portable版では、起動しているREAPERのResource Pathを確認してください。 |
| SoundPrepが見つからない／古い版しか表示されない | `Manage repositories…` でSoundPrepのURLが上記の `/releases/latest/download/index.xml` になっているか確認し、`Synchronize packages` を実行します。Browse packagesのフィルターや、特定の版に固定していないかも確認します。 |
| Action Listに見当たらない | ReaPackでInstall後にApplyしたか確認し、Action ListのSectionをMainにして `SoundPrep.lua` を検索します。 |
| SWS／JS_ReaScriptAPI不足と表示される | 該当する拡張を使用中のREAPERへ導入し、REAPERを再起動します。 |
| Native helper不足／更新が必要と表示される | ReaPackの更新がエラーなく完了しているか確認し、REAPERを再起動します。別のREAPERやPortable版を起動していないかも確認してください。 |
| 以前の追加Actionsがたくさん残っている | 既存のキー割当を保持するため、そのまま残しています。通常起動には `SoundPrep.lua` だけを使ってください。 |

解決しない場合は、上の「追加Actions」の方法で `SoundPrep - Diagnostics.lua` をMainに登録して実行すると、依存関係やhelperの状態を確認できます。診断を共有するときは、REAPERの版、OS、表示されたエラーを添えてください。診断結果にはローカルのパスが含まれます。

## 旧Audition Macroから切り替える

旧Audition MacroをQuitし、bank・FXチェーンなどを含む `data/` 全体と必要なキー割当をバックアップしてください。旧版を手動導入していた場合は、ReaPackでSoundPrepを導入し、起動前に新しい `SoundPrep.lua` と同じ階層へ `data/` を引き継ぎます。

旧名の互換スクリプトは廃止しました。旧Actionsへのキー割当は自動移行されません。追加Actionsが必要な場合は上記の手順で登録し、対応するSoundPrepのActionsへ手動で割り当て直してから、不要な旧Actionsの登録を削除してください。手動導入した旧フォルダーや開発フォルダーに残る `Audition Macro*.lua` も削除できます。Native helper・JSFX・保存データの内部識別名は引き続き使用するため、名前を変更したり削除したりしないでください。

### 旧ReaPackパッケージから切替

旧Audition MacroとSoundPrepは、同じ `UserPlugins/reaper_audition_macro.dll`（macOSでは `.dylib`）を所有するため、両パッケージを共存導入できません。SoundPrepは `Scripts/SoundPrep/` 以下の別パッケージで、設定は自動移行しません。

1. 旧Audition MacroをQuitし、bank・FXチェーンなどを含む旧 `data/` 全体をバックアップします。必要なキー割当も記録してください。
2. ReaPackの `Browse packages…` で旧Audition Macroパッケージを選び、`Uninstall` をApplyします。作業を保存してREAPERを再起動し、旧パッケージの削除が完了したことを確認します。
3. このページのSoundPrep用ReaPack URLを登録し、新パッケージを導入します。新しいhelperを読み込むため、作業を保存してREAPERを再起動します。
4. SoundPrepを起動する前に、バックアップした `data/` 全体を、新しい `SoundPrep.lua` と同じ階層の `data/` へ引き継ぎます。
5. 必要に応じて追加Actionsを登録してキーを割り当て直し、`SoundPrep.lua` を実行します。

旧パッケージのアンインストールでは旧Actionsの登録も解除されます。必要なキー割当はSoundPrepのActionsへ手動で引き継いでください。

設定を引き継いでからSoundPrepを起動してください。新旧を同時に起動せず、切り替えるときは実行中の方をQuitします。

## 最初の確認

Ambisonicsは1〜10次AmbiX（ACN/SN3D、4〜121ch）を入力として扱い、W/Yのみで簡易ステレオ試聴します。高次成分の空間デコードは行いません。

短い音声ファイルでPlay／StopとMacro切替を確認します。Normalizeを使う場合は、解析中にD&Dしても一時ミュートで配置され、完了後に補正が適用されることを確認します。3ch以上ではDownmixを選べます。OFFは元ch数とch間の比率を保持し、Macro FXをバイパスします。ONはステレオへまとめ、Macro FXを適用します。

Masterが2chのプロジェクトで3ch目以降も聴きたい場合は、DownmixをONにするか、プロジェクトの出力ルーティングを設定してください。SoundPrepはMaster設定を変更しません。

helperや依存APIが見つからない場合はMain Actionの `SoundPrep - Diagnostics.lua` で状態を確認できます。旧helperの更新後も案内が出る場合は、REAPERを再起動したことと、使用中のResource Pathを確認してください。

多chのSource + FXを別の環境で開く場合は、使用したMacro FXに加えて `Effects/AuditionMacro/channels_v1` が必要です。この専用JSFXは最初の多ch D&Dで配置します。

本プロジェクトの独自部分のライセンスは[MIT](../LICENSE)です。MoSQITo由来のコードにはApache-2.0など、それぞれの第三者ライセンスが適用されます。第三者コードの出典とライセンスは[第三者ライセンスと出典](../THIRD_PARTY_NOTICES.md)に記載しています。

公開済みのLua・Nativeソースは維持し、v0.11.0で追加した解析エンジンは既存helperのDLL／dylibに同梱して配布します。独自部分のMITは変更しません。ソースの公開範囲は[配布方針](source-distribution.md)を参照してください。
---

[READMEに戻る](../README.md) · [MIT Licenseの案内](license.md) · [第三者ライセンスと出典](../THIRD_PARTY_NOTICES.md)
