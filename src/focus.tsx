import { Action, ActionPanel, closeMainWindow, Color, Icon, List, open, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { selfControlPath } from "./lib/storage";
import Groups from "./groups";
import Statistics from "./statistics";
import { countdown } from "./lib/model";
import { useSessions } from "./lib/use-sessions";

export default function Focus() {
  const { data, isLoading, error, now, trackerRunning, refresh } = useSessions();
  const current = data.find((session) => session.actualEnd === undefined);
  const remaining = current ? current.plannedEnd - now : 0;
  const color = remaining <= 60000 ? Color.Red : remaining <= 300000 ? Color.Orange : Color.Green;
  async function openSelfControl() {
    try { await open(await selfControlPath()); await closeMainWindow(); }
    catch (err) { await showToast({ style: Toast.Style.Failure, title: "Could not open SelfControl", message: err instanceof Error ? err.message : undefined }); }
  }
  async function restartTracker() {
    try {
      await promisify(execFile)("/bin/launchctl", ["kickstart", `gui/${process.getuid?.()}/local.focusledger.tracker`]);
      await showToast({ style: Toast.Style.Success, title: "Tracker started" });
      await refresh();
    } catch { await showToast({ style: Toast.Style.Failure, title: "Could not start tracker", message: "Run the helper installer from the project folder." }); }
  }
  return <List isLoading={isLoading} searchBarPlaceholder="Choose an action">
    {error ? <List.Item icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }} title="Could not read history" subtitle={error} /> :
      <List.Item icon={{ source: Icon.Circle, tintColor: trackerRunning === false ? Color.Red : current ? color : Color.SecondaryText }}
        title={trackerRunning === false ? "Tracker not running" : current ? (remaining > 0 ? "Block in progress" : "Waiting for SelfControl") : "Ready for your next block"}
        subtitle={trackerRunning === false ? "Start tracker to record blocks" : current ? current.name : undefined}
        actions={<ActionPanel>{trackerRunning === false ? <Action title="Start Tracker" onAction={restartTracker} /> : <Action title="Open SelfControl" onAction={openSelfControl} />}<Action.Push title="View Statistics" target={<Statistics />} /><Action.Push title="View Groups" target={<Groups />} /></ActionPanel>} />}
    {trackerRunning !== false && current && <List.Item icon={{ source: Icon.Clock, tintColor: remaining > 0 ? color : Color.Orange }} title={remaining > 0 ? `${countdown(remaining)} remaining` : "Awaiting update"} actions={<ActionPanel><Action title="Open SelfControl" onAction={openSelfControl} /></ActionPanel>} />}
    <List.Item icon={Icon.Play} title="Open SelfControl" actions={<ActionPanel><Action title="Open SelfControl" onAction={openSelfControl} /></ActionPanel>} />
    <List.Item icon={Icon.BarChart} title="View Statistics" actions={<ActionPanel><Action.Push title="View Statistics" target={<Statistics />} /></ActionPanel>} />
    <List.Item icon={Icon.Folder} title="Subjects / Groups" actions={<ActionPanel><Action.Push title="View Groups" target={<Groups />} /></ActionPanel>} />
  </List>;
}
