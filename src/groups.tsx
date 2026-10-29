import { Action, ActionPanel, Form, Icon, List, showToast, Toast, useNavigation } from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { addGroup, groups } from "./lib/storage";

function CreateGroup({ onSaved }: { onSaved: () => void }) {
  const { pop } = useNavigation();
  async function submit(values: { name: string }) {
    try {
      const result = await addGroup(values.name);
      await showToast({ style: Toast.Style.Success, title: result.existing ? "Group already exists" : "Group created", message: result.name });
      onSaved(); pop();
    } catch (error) {
      await showToast({ style: Toast.Style.Failure, title: "Could not create group", message: error instanceof Error ? error.message : undefined });
    }
  }
  return <Form actions={<ActionPanel><Action.SubmitForm title="Save Group" onSubmit={submit} /></ActionPanel>}>
    <Form.TextField id="name" title="Subject / Group" placeholder="e.g. Mathematics" />
    <Form.Description text="This group will be offered when you start a SelfControl block." />
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
  return <List isLoading={isLoading} searchBarPlaceholder="Search subjects or groups">
    <List.Item icon={Icon.Plus} title="Create Group" actions={<ActionPanel><Action.Push title="Create Group" target={<CreateGroup onSaved={refresh} />} /></ActionPanel>} />
    {error && <List.Item icon={Icon.ExclamationMark} title="Could not read groups" subtitle={error} actions={<ActionPanel><Action title="Retry" onAction={refresh} /></ActionPanel>} />}
    {names.length > 0 && <List.Section title="Subjects / Groups">
      {names.map((name) => <List.Item key={name} icon={Icon.Folder} title={name} subtitle="Available when starting a block" actions={<ActionPanel><Action.Push title="Create Group" target={<CreateGroup onSaved={refresh} />} /></ActionPanel>} />)}
    </List.Section>}
  </List>;
}
