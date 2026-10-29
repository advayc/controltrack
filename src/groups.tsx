import { Action, ActionPanel, confirmAlert, Alert, Form, Icon, List, showToast, Toast, useNavigation } from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { addGroup, groups, renameGroup, deleteGroup } from "./lib/storage";

export function GroupForm({ original, onSaved }: { original?: string; onSaved: () => void }) {
  const { pop } = useNavigation();
  async function submit(values: { name: string }) {
    const toast = await showToast({ style: Toast.Style.Animated, title: original ? "Renaming group" : "Creating group" });
    try {
      if (original) {
        await renameGroup(original, values.name);
        toast.title = "Group renamed";
      } else {
        const result = await addGroup(values.name);
        toast.title = result.existing ? "Group already exists" : "Group created";
        toast.message = result.name;
      }
      toast.style = Toast.Style.Success;
      onSaved(); pop();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = original ? "Could not rename group" : "Could not create group";
      toast.message = error instanceof Error ? error.message : undefined;
    }
  }
  return <Form actions={<ActionPanel><Action.SubmitForm title={original ? "Save Group Name" : "Save Group"} onSubmit={submit} /></ActionPanel>}>
    <Form.TextField id="name" title="Subject / Group" defaultValue={original} placeholder="e.g. Mathematics" />
    <Form.Description text={original ? "Renaming a group also updates its existing sessions." : "This group will be offered when you start a SelfControl block."} />
  </Form>;
}

export default function Groups() {
  const [names, setNames] = useState<string[]>([]);
  const [isLoading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const refresh = useCallback(async () => {
    try { setNames(await groups()); setError(undefined); }
    catch (err) { setError(err instanceof Error ? err.message : "Could not read groups."); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);
  async function remove(name: string) {
    if (!await confirmAlert({ title: "Delete this group?", message: "Its sessions will stay in your history without a subject.", primaryAction: { title: "Delete Group", style: Alert.ActionStyle.Destructive } })) return;
    const toast = await showToast({ style: Toast.Style.Animated, title: "Deleting group" });
    try { await deleteGroup(name); toast.style = Toast.Style.Success; toast.title = "Group deleted"; await refresh(); }
    catch (error) { toast.style = Toast.Style.Failure; toast.title = "Could not delete group"; toast.message = error instanceof Error ? error.message : undefined; }
  }
  return <List isLoading={isLoading} searchBarPlaceholder="Search subjects or groups">
    <List.Item icon={Icon.Plus} title="Create Group" actions={<ActionPanel><Action.Push title="Create Group" target={<GroupForm onSaved={refresh} />} /></ActionPanel>} />
    {error && <List.Item icon={Icon.ExclamationMark} title="Could not read groups" subtitle={error} actions={<ActionPanel><Action title="Retry" onAction={refresh} /></ActionPanel>} />}
    {names.length > 0 && <List.Section title="Subjects / Groups">
      {names.map((name) => <List.Item key={name} icon={Icon.Folder} title={name} subtitle="Available when starting a block" actions={<ActionPanel><Action.Push title="Rename Group" target={<GroupForm original={name} onSaved={refresh} />} /><Action.Push title="Create Group" target={<GroupForm onSaved={refresh} />} /><Action title="Delete Group" style={Action.Style.Destructive} onAction={() => remove(name)} /></ActionPanel>} />)}
    </List.Section>}
  </List>;
}
