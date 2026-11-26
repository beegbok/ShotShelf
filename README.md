# SC Pro

A menu-bar shelf of your recent screenshots. Click one to copy it, or drag it into another app. New screenshots can land on the clipboard on their own.

Created by DLProjects.

## Download

[SC Pro 1.0 for Mac](https://github.com/beegbok/ShotShelf/releases/latest/download/ShotShelf.zip)

Needs an Apple silicon Mac on macOS 14 or later. Unzip it and move `SC Pro.app` to Applications, then open it.

SC Pro lives in the menu bar, not the Dock. Click the photo icon. The first time it reads your Desktop it will ask for folder access.

## Build it yourself

```sh
./build.sh
```

That runs the tests, builds `build/SC Pro.app`, zips `build/ShotShelf.zip`, and installs a copy in `~/Applications`.
