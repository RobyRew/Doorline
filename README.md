# Doorline

SwiftUI app for iPhone, iPad, and Mac. It keeps two paths:

- A Classe 300X session: account and plant link, incoming call (ringing, answer with audio and video, or decline), camera choice, a door-lock release that is separate from a gate or other actuator, call-home to the internal unit, answering-machine messages, call forwarding, professional studio, and a history of calls and unlocks.
- Apple Home, on iPhone and iPad: the lock, camera, and door sensor already in Home, plus the existing Siri shortcuts.

Commands are addressed to the plant you save. The myhomeweb portal has to accept them before they reach the panel. A rejected portal response stays a rejection.

## Requirements

- Xcode 16 or newer
- iOS 17, iPadOS 17, or macOS 14
- An Apple Developer team with the HomeKit and Siri capabilities enabled for `com.doorline.home` when you use the Home tab
- A device signed into the same Apple Account as the home, if you use Home. The simulator has no real home.

Liquid Glass is used for the entrance controls when the SDK you compile with declares it (Xcode 26). Earlier SDKs keep the system material styles, so the iOS 17 deployment still builds on Xcode 16.4.

## Run

1. Open `Doorline.xcodeproj`.
2. Select the Doorline target and set your Team.
3. Run on your iPhone, iPad, or Mac.
4. On Entrance, sign in with the same email and password as Door Entry. Eliot returns the Classe 300X on that account.
5. On iPhone or iPad, open Home if you also want a HomeKit lock. Allow Home access when asked, then pick the lock, camera, and contact sensor.

## Siri

The Home shortcuts are unchanged. Enable them the first time Siri offers them, or add them in the Shortcuts app:

- “Open the door with Doorline”
- “Lock the door with Doorline”
- “Is the door open in Doorline”
- “Show the entrance in Doorline”

Those phrases write the HomeKit lock. They do not pulse the Classe 300X strike. The entrance tab does that with a separate door-lock command.

## Layout

```text
Doorline.xcodeproj                 project and shared scheme
Doorline/DoorlineApp.swift         app entry
Doorline/Classe300XSession.swift   Classe 300X state the screens call
Doorline/C300XCodec.swift          bus, SIP, and portal frames
Doorline/Classe300XView.swift      entrance, call, messages, history
Doorline/DoorGlass.swift           Liquid Glass, or a system material
Doorline/HomeStore.swift           HomeKit reads and writes
Doorline/EntranceView.swift        Home camera still, lock, sensor, picker
Doorline/DoorIntents.swift         Siri intents and shortcuts
Doorline/Theme.swift               colors
DoorlineTests/                     session tests
.github/workflows/ci.yml           unsigned iOS and macOS builds
```

## Continuous integration

`.github/workflows/ci.yml` builds the iOS Simulator and macOS destinations on every push and pull request to `main` or `master`. Signing is off in CI. A real device build still needs your team in Xcode.

Derived data, user schemes, and provisioning files stay out of git. See `.gitignore`.
