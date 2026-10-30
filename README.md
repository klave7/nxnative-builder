# NxNative Builder

A native macOS app that sets up everything [seedds/nxnative](https://github.com/seedds/nxnative) needs, then turns folders of Nintendo Switch game files into unsigned iPhone IPAs, several games at a time. It is an independent helper and is not affiliated with seedds/nxnative.

You supply your own game files and `prod.keys`. Nothing is downloaded or included for you, and no keys or game data ever leave your Mac.

## What it does

- **Setup.** Checks Xcode, the iOS platform, the Metal compiler, Homebrew, Python 3.12, XcodeGen, zstd, glslang and .NET, and installs what is missing. Every step asks first and shows the exact command. The setup page is skipped when everything is already there.
- **Seedds nxnative.** Downloads the project into the app's own folder. Updating is optional: **Check for updates** shows what is new, and the downloaded copy keeps working without it.
- **Patches.** Three optional patches to nxnative, applied one at a time with a green check when applied: blurred bars around the picture, an in-game control editor, and portrait mode for the iPhone Duo. The bars and the control editor are independent of each other (any one alone, any order); the Duo patch needs both, and a patch comes off only while no applied patch needs it.
- **Build queue.** Pick a games folder with one subfolder per game (or a single NSP folder), name each game, and queue them. The name is checked against what the iPhone home screen can show and warns when it would be cut with "…". Choose the output folder for the IPAs. Optionally delete each game's build folders (`<title ID>_build`, `_survey`, `-work`) and the IPA's `.idx` file after it finishes, which frees many GB.
- **Uninstall.** Lists what the app left on your Mac with sizes and removes it on your say-so. Homebrew packages are kept unless you tick them.

It follows the system Light/Dark setting.

## Use it

Download `NxNative-Builder.zip` from the [latest release](../../releases/latest), unzip, and move the app anywhere. The app is ad-hoc signed and not notarized, so the first time, right-click it and choose **Open**. It runs on Apple silicon and Intel Macs (the games themselves need Apple silicon to build, as nxnative's host does).

Everything the app ships is inside the `.app`. What it downloads, and its settings and queue, go to `~/Library/Application Support/NxNative Builder`. Xcode is the one thing it cannot install: it opens the App Store page.

## Build it yourself

Needs Xcode's `swiftc`:

```
./build_app.sh
```

This makes `NxNative Builder.app` next to the script. To remake the icon from `icon-source.png`: `swiftc make_icon.swift -o make_icon && ./make_icon icon-source.png AppIcon.icns`.

The patches in `patches/` apply to the Seedds main as of 2026-10-30. The bars and the control editor are independent: apply either one alone, or both in any order. Portrait mode needs both (a `Requires:` line in its header), so the app keeps it locked until they are on. When Seedds changes the same code, a patch shows a red mark in the app, and needs to be regenerated.

## License

MIT, see [LICENSE](LICENSE). The patches modify seedds/nxnative (MIT, [notice](licenses/seedds-nxnative-LICENSE)).
