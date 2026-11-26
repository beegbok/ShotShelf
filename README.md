# ShotShelf

A menu-bar shelf of your recent screenshots. Click one to copy it, or drag it into another app. New screenshots can land on the clipboard on their own.

Created by DLP.

## Download

[ShotShelf 1.0 for Mac](https://github.com/beegbok/ShotShelf/releases/latest/download/ShotShelf.zip)

Needs an Apple silicon Mac on macOS 14 or later. Unzip it and move `ShotShelf.app` to Applications, then open it.

ShotShelf lives in the menu bar, not the Dock. Click the photo icon. The first time it reads your Desktop it will ask for folder access.

## Build it yourself

```sh
./build.sh
```

That runs the tests, builds `build/ShotShelf.app`, zips `build/ShotShelf.zip`, and installs a copy in `~/Applications`.
