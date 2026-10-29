import { Action, ActionPanel, Color, Form, Icon, List, showToast, Toast, useNavigation } from "@raycast/api";
import { countdown, duration, elapsed, groupTotals, lastSevenDays, normalizeName, type Session } from "./lib/model";
import { GroupForm } from "./groups";
import { renameSession } from "./lib/storage";
import { useSessions } from "./lib/use-sessions";

function RenameSession({ session, onSaved }: { session: Session; onSaved: () => void }) {
  const { pop } = useNavigation();
  async function submit(values: { name: string }) {
    const toast = await showToast({ style: Toast.Style.Animated, title: "Updating session" });
    try {
      await renameSession(session.id, values.name);
      onSaved(); toast.style = Toast.Style.Success; toast.title = "Session updated"; pop();
    } catch (error) {
      toast.style = Toast.Style.Failure; toast.title = "Could not update session"; toast.message = error instanceof Error ? error.message : undefined;
    }
  }
  return <Form actions={<ActionPanel><Action.SubmitForm title="Save Subject" onSubmit={submit} /></ActionPanel>}>
    <Form.TextField id="name" title="Subject / Group" defaultValue={session.name === "Focus session" ? "" : session.name} placeholder="e.g. Mathematics" />
    <Form.Description text="Use an existing subject or enter a new one." />
  </Form>;
}

export default function Statistics() {
  const { data, isLoading, error, now, refresh, trackerRunning } = useSessions();
  const days = lastSevenDays(data, new Date(now));
  const maximum = Math.max(...days.map((day) => day.ms), 1);
  const totals = groupTotals(data, now);
  const active = data.find((session) => session.actualEnd === undefined);
  const activeRemaining = active ? active.plannedEnd - now : 0;
  const statusColor = activeRemaining <= 60000 ? Color.Red : activeRemaining <= 300000 ? Color.Orange : Color.Green;
  return <List isLoading={isLoading} searchBarPlaceholder="Search subjects or sessions">
    {error && <List.Item icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }} title="Could not read history" subtitle={error} actions={<ActionPanel><Action title="Retry" onAction={refresh} /></ActionPanel>} />}
    {trackerRunning === false && <List.Item icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }} title="Tracker not running" subtitle="New blocks won't be recorded until it starts." />}
    {active && <List.Section title="Current Block">
      <List.Item icon={{ source: Icon.Circle, tintColor: activeRemaining > 0 ? statusColor : Color.Orange }} title={trackerRunning === false ? "Last recorded block" : activeRemaining > 0 ? "Block in progress" : "Waiting for SelfControl"} subtitle={active.name} accessories={[{ text: trackerRunning === false ? "Tracker offline" : activeRemaining > 0 ? countdown(activeRemaining) : "Awaiting update" }]} actions={<ActionPanel><Action.Push title="Rename Session" target={<RenameSession session={active} onSaved={refresh} />} /></ActionPanel>} />
    </List.Section>}
    <List.Section title="Last 7 Days" subtitle={`${duration(days.reduce((sum, day) => sum + day.ms, 0))} total`}>
      {days.map((day) => <List.Item key={day.date.toISOString()} icon={Icon.Calendar} title={day.date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })} subtitle={day.ms > 0 ? "▰".repeat(Math.max(1, Math.round(day.ms / maximum * 12))) : "—"} accessories={[{ text: duration(day.ms) }]} />)}
    </List.Section>
    {totals.length > 0 && <List.Section title="Subjects / Groups" subtitle="All time">
      {totals.map((group) => <List.Item key={group.name} icon={Icon.Folder} title={group.name} accessories={[{ text: duration(group.ms) }]} actions={normalizeName(group.name) === normalizeName("Focus session") ? undefined : <ActionPanel><Action.Push title="Rename Group" target={<GroupForm original={group.name} onSaved={refresh} />} /></ActionPanel>} />)}
    </List.Section>}
    {data.length > 0 && <List.Section title="Sessions" subtitle={`${data.length} recorded`}>
      {data.map((session) => <List.Item key={session.id} icon={Icon.Clock} title={session.name} subtitle={new Date(session.start).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })} accessories={[{ text: duration(elapsed(session, now)) }]} actions={<ActionPanel><Action.Push title="Rename Session" target={<RenameSession session={session} onSaved={refresh} />} /></ActionPanel>} />)}
    </List.Section>}
    {!isLoading && !error && data.length === 0 && <List.Section title="Sessions"><List.Item icon={Icon.Clock} title="No sessions recorded yet" subtitle="Start a block in SelfControl to begin tracking." /></List.Section>}
  </List>;
}
