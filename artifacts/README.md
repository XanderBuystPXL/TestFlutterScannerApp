# Shared device builds

**Current source is 0.2.1 (4), with package-path correction and retry from saved capture files.** Build it in Codemagic and confirm the installed version. Install over the existing app to preserve failed captures, then use Retry saving last scan. No new IPA has been generated locally. The old artifact below remains unchanged and must not be mistaken for the latest app.

`RoomPlanTest-unsigned.ipa` is the original **0.1.0 (1)** Codemagic build. Its package metadata was checked locally. The accompanying ZIP contains build 1's Codemagic artifacts.

**That IPA does not contain the JSON read-back fix in source version 0.1.1 (2).** Re-run the Codemagic workflow on the latest `main`, download the new IPA, and replace the shared IPA only after checking its version. The fixed app displays **App version: 0.1.1 (2)** on its home screen.

Keep the same Apple account and bundle ID when installing the update over the existing app so its saved diagnostics can be preserved.
