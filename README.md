# Corner Lock

Press one button and a small image appears in all four corners of your screen.
It stays for 24 hours, works fully offline, and can't be turned off from the app until the time is up.

The default image is a compass star. You can pick any image of your own before locking.

---

## Pixel 8 (Android)

The `android` folder is the app's source. It has to be built into an `.apk` once.
Pick one way:

### Option A: build it on GitHub (no software to install)
1. Make a free account on github.com and create a new **private** repository.
2. Upload the *contents* of the `android` folder (including the hidden `.github` folder) to it.
   On a computer: "Add file" > "Upload files", then drag everything in.
3. Open the **Actions** tab. A build named "Build APK" starts by itself and takes about 3 minutes.
4. When it shows a green tick, open it and download **CornerLock-apk** at the bottom (a zip with `app-debug.apk` inside).

### Option B: Android Studio
1. Install Android Studio, then File > Open > the `android` folder.
2. Build > Build App Bundle(s) / APK(s) > Build APK(s).

### Install on the phone
1. Copy `app-debug.apk` to the Pixel and tap it. Allow "Install unknown apps" for the app you opened it with.
2. Open **Corner Lock**, allow notifications.
3. "Choose image" (optional), then "Lock for 24 hours".
4. The first time, it sends you to the **Display over other apps** setting. Turn it on for Corner Lock, go back, press Lock again.

Notes
- The corner images are 80% opaque. Android requires that so your taps still go through to whatever is underneath.
- A small "Corner Lock is on" notification stays while it runs. That's what keeps Android from killing it.
- After a restart it comes back by itself.

---

## Windows

1. Keep `CornerLock.bat`, `CornerLock.ps1` and `image.png` together in one folder.
2. Double-click `CornerLock.bat`.
3. "Choose image..." (optional), then "Lock for 24 hours".

The images sit in the four corners of every monitor, on top of everything, and clicks pass straight through them.
If the overlay is closed (Task Manager) or the PC restarts, it comes back within a minute.
After 24 hours it removes itself and cleans up.

If Windows SmartScreen or your antivirus asks about the `.bat`, choose "Run anyway". Nothing is installed; it uses PowerShell, which every Windows PC already has.

---

## How firm is the lock?

It's a commitment device, not a cage. Nothing on a phone or PC you own can be made truly impossible to remove without a managed-device setup.
Inside the apps there is no way to cancel. Outside them, you could still get rid of it by:

- **Android:** uninstalling, force-stopping it in Settings, turning off "Display over other apps", or changing the phone's clock.
- **Windows:** deleting the "CornerLock" scheduled task, or the folder `%LOCALAPPDATA%\CornerLock`, or changing the clock.

Each of those takes deliberate steps, which is the point.
