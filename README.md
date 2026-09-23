# Doorline

SwiftUI app for iPhone, iPad, and Mac. It controls a lock, a camera, and a door sensor that are already in Apple Home, and it exposes those actions to Siri.

It does not connect to a BTicino Classe 300X. HomeKit only lists accessories the Home app already has. The 300X is not a Home accessory, so its video and its door pulse never appear here.

## Requirements

- Xcode 16 or newer
- iOS 17, iPadOS 17, or macOS 14
- An Apple Developer team with the HomeKit and Siri capabilities enabled for `com.doorline.home`
- A device signed into the same Apple Account as the home. The simulator has no real home.

## Run

1. Open `Doorline.xcodeproj`.
2. Select the Doorline target and set your Team.
3. Run on your iPhone, iPad, or Mac.
4. Allow Home access when asked.
5. Open the slider and pick the home, the lock, the camera, and the contact sensor.

## Siri

Enable the shortcuts the first time Siri offers them, or add them in the Shortcuts app. The phrases are:

- “Open the door with Doorline”
- “Lock the door with Doorline”
- “Is the door open in Doorline”
- “Show the entrance in Doorline”

“Open” writes the HomeKit unlock value. It does not pulse a Classe 300X strike. “Lock” only works if the accessory you picked can actually lock.

## Layout

```text
Doorline.xcodeproj          project and shared scheme
Doorline/DoorlineApp.swift  app entry
Doorline/HomeStore.swift    HomeKit reads and writes
Doorline/EntranceView.swift camera still, lock, sensor, picker
Doorline/DoorIntents.swift  Siri intents and shortcuts
Doorline/Theme.swift        colors
.github/workflows/ci.yml    unsigned iOS and macOS builds
```

## Continuous integration

`.github/workflows/ci.yml` builds the iOS Simulator and macOS destinations on every push and pull request to `main` or `master`. Signing is off in CI. A real device build still needs your team in Xcode.

Derived data, user schemes, and provisioning files stay out of git. See `.gitignore`.
