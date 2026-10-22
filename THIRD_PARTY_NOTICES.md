# Third-party components

This inventory distinguishes the shipped iOS app from desktop intake and optional research execution. Full copyright/licence texts must travel with redistributed dependencies; this index does not replace them or grant rights to project-owned code.

| Component | Scope | Licence/terms and notice location |
| --- | --- | --- |
| Flutter 3.35.4 / Dart / engine and bundled assets | iOS binary | Flutter BSD-3-Clause plus engine/asset/dependency notices. SDK LICENSE copied to CI artifacts; generated NOTICES bundled by Flutter and accessible through the app licence screen. Review exact binary before release. |
| Apple system frameworks | iOS device | Apple SDK and developer/distribution agreements; public system APIs, not copied framework implementations. |
| NumPy 2.3.5 | Desktop intake/CI only | BSD-3-Clause plus bundled wheel notices (e.g. BLAS); full texts in installed distribution's licence directory. |
| Pillow 12.3.0 | Desktop intake/CI only | MIT-CMU/PIL licence plus bundled codec notices in installed distribution. |
| Python standard library | Desktop/CI runtime | PSF licence and bundled-component notices supplied with Python. |
| gsplat and existing research environment | Optional external GPU PoC | gsplat Apache-2.0; remaining exact environment requires separate deployment review. No GPU dependencies or weights bundled in app/intake scripts. |

Flutter runtime pub dependencies are locked in `pubspec.lock`; no third-party Flutter plugin was added. `flutter_lints`/`flutter_test` and their dependencies are development tools, not capture SDKs. Material icons and font/engine notices remain in Flutter's generated bundle notices.

Codemagic publishes `flutter-dependencies.json`, `python-dependencies.json`, `FLUTTER-LICENSE.txt` and this inventory alongside logs. Python dependencies are installed from their own distributions, which supply full licence texts. If distributing a preassembled desktop/GPU environment, include all of those texts and audit native bundled libraries as well.

Sources: [Flutter pinned licence](https://github.com/flutter/flutter/blob/3.35.4/LICENSE), [NumPy licences](https://numpy.org/doc/stable/license.html), [Pillow licence](https://github.com/python-pillow/Pillow/blob/main/LICENSE), [Python licence](https://docs.python.org/3/license.html), [gsplat licence](https://github.com/nerfstudio-project/gsplat/blob/main/LICENSE).
