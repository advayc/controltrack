# SelfControl Tracker

A compact macOS companion and optional Raycast extension for the [SelfControl](https://selfcontrolapp.com/) app. SelfControl continues to run the timer and block websites. The tracker detects actual blocks, asks for a subject or group, and records the session locally.

## Use

- Click the SelfControl icon in the menu bar to open the compact tracker; choose **View Statistics** for the weekly chart and session history. Click the icon again or close the window to dismiss it.
- You can also run **SelfControl Tracker** in Raycast to see the current block, remaining time, and actions.
- Choose **Open SelfControl** to set the duration and start a block in the original app. After the block starts, enter a new subject or select an existing one when prompted.
- Choose **View Statistics** for the last seven days, totals by subject, and recorded sessions. Select a session to rename it.
- Choose **Subjects / Groups** to create a group in advance. Groups typed in the prompt are saved too.

The status indicator is green while a block has more than five minutes left, amber for the last five minutes, and red for the last minute. The helper starts at login, has no Dock icon, and keeps tracking when either window closes.

## Example weekly view

![Compact statistics window showing example study times across a week, with totals by subject](media/weekly-view.png)

The image uses fictional study sessions and shows a resized version of the compact statistics window.

## Setup

The compact popup requires macOS, SelfControl, and the Apple command-line developer tools. A full Xcode installation is not required. Install the popup and background tracker with:

```sh
./scripts/install-helper.sh
```

The installer builds and ad-hoc signs a small local app, installs a user LaunchAgent, and preserves an existing installation if startup fails.

To also use Raycast, install Raycast, Node.js 22.14 or later, and npm, then run:

```sh
npm install
npm run dev
```

Run `npm run dev` once to import the extension into Raycast; after it builds, stop the development process with Ctrl-C. Raycast keeps the imported extension. Raycast may require you to be signed in to use its development commands.

Raycast is optional after the helper is installed. The extension checks whether the helper is running and can start it from its status view if its LaunchAgent is registered. To stop tracking for the current login session, run `launchctl bootout gui/$(id -u)/local.focusledger.tracker`. To start it again without logging out, run `launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/local.focusledger.tracker.plist"`.

## Data and limitations

Session history and groups stay on your Mac in `~/Library/Application Support/Focus Ledger/`. The directory name preserves compatibility with the original local tracker. The extension does not send session data to a server, and this repository contains no personal history.

SelfControl does not retain a full history or expose its block start time. The helper records the time when it notices a new block, typically within five seconds, and follows changes to the scheduled end time. It cannot recover blocks that begin and end while the helper is not running. If the helper first sees an already-running block, its recorded start is the detection time. SelfControl's internal settings format may change in a future version.

Run `npm test`, `npm run typecheck`, and `npm run build` to check the extension. `scripts/install-helper.sh` runs the helper's isolated self-test. These tests do not start a real SelfControl block.

## License and attribution

GPL-3.0-or-later; see [LICENSE](LICENSE). The icon is copied from the icon in the [SelfControl source repository](https://github.com/SelfControlApp/selfcontrol). This project is independent of SelfControl and Raycast.
