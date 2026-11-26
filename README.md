# ShotShelf

A menu-bar shelf of your recent screenshots. Click one to copy it, or drag it into another app. New screenshots can land on the clipboard on their own.

Created by DLP.

## Download

[ShotShelf 1.0 for Mac](https://github.com/beegbok/ShotShelf/releases/latest/download/ShotShelf.zip)

Needs an Apple silicon Mac on macOS 14 or later. After you unzip it, move `ShotShelf.app` to Applications.

macOS will refuse the first open, because this build is not notarized. Right-click the app, choose Open, then Open again. If that still fails, go to System Settings → Privacy & Security and choose Open Anyway.

ShotShelf lives in the menu bar, not the Dock. Click the photo icon. The first time it reads your Desktop it will ask for folder access.

## Build it yourself

```sh
./build.sh
```

That runs the tests, builds `build/ShotShelf.app`, zips `build/ShotShelf.zip`, and installs a copy in `~/Applications`.
