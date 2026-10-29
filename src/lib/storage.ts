import { randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { normalizeName, readSession, uniqueGroups, type Session } from "./model";

export const root = path.join(os.homedir(), "Library", "Application Support", "Focus Ledger");
const archivePath = path.join(root, "sessions.json");
const groupPath = path.join(root, "groups");
const commandPath = path.join(root, "commands");
type Archive = { sessions: Session[]; groupNames: string[]; importedGroupFiles: Set<string>; groupColors: Record<string, number> };

async function readArchive(): Promise<Archive> {
  let data: string;
  try { data = await fs.readFile(archivePath, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { sessions: [], groupNames: [], importedGroupFiles: new Set(), groupColors: {} };
    throw error;
  }
  const parsed: unknown = JSON.parse(data);
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as { sessions?: unknown }).sessions)) throw new Error("The session history is not in the expected format.");
  const archive = parsed as { sessions: unknown[]; groupNames?: unknown; importedGroupFiles?: unknown; groupColors?: Record<string, number> };
  const result = archive.sessions.map(readSession);
  if (result.some((session) => session === null)) throw new Error("A session in the history is not in the expected format.");
  if (archive.groupNames !== undefined && (!Array.isArray(archive.groupNames) || archive.groupNames.some((name) => typeof name !== "string"))) throw new Error("The group list is not in the expected format.");
  if (archive.importedGroupFiles !== undefined && (!Array.isArray(archive.importedGroupFiles) || archive.importedGroupFiles.some((name) => typeof name !== "string"))) throw new Error("The group history is not in the expected format.");
  return {
    sessions: (result as Session[]).sort((a, b) => b.start - a.start),
    groupNames: (archive.groupNames ?? []) as string[],
    importedGroupFiles: new Set((archive.importedGroupFiles ?? []) as string[]),
    groupColors: archive.groupColors ?? {},
  };
}

export async function sessions(): Promise<Session[]> {
  return (await readArchive()).sessions;
}

export async function groups(history?: Session[]): Promise<string[]> {
  const archive = await readArchive();
  const legacy: string[] = [];
  let files: string[];
  try { files = await fs.readdir(groupPath); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    files = [];
  }
  for (const file of files.filter((name) => name.endsWith(".json") && !archive.importedGroupFiles.has(name))) {
    try {
      const value: unknown = JSON.parse(await fs.readFile(path.join(groupPath, file), "utf8"));
      if (typeof value === "string") legacy.push(value);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return uniqueGroups([...archive.groupNames, ...legacy, ...(history ?? archive.sessions).map((session) => session.name)]);
}

export function validateName(input: string): string {
  const name = input.trim();
  if (!name) throw new Error("Enter a subject or group.");
  if (name.length > 120 || /[\r\n\u0000-\u001f]/.test(name)) throw new Error("Use a single line of at most 120 characters.");
  if (normalizeName(name) === normalizeName("Focus session")) throw new Error("Choose a name other than the default ‘Focus session’.");
  return name;
}

async function sendCommand(command: Record<string, unknown>): Promise<void> {
  await fs.mkdir(commandPath, { recursive: true });
  const id = randomUUID();
  const request = path.join(commandPath, `${id}.json`);
  const temporary = path.join(commandPath, `${id}.tmp`);
  const response = path.join(commandPath, `${id}.result`);
  try {
    await fs.writeFile(temporary, JSON.stringify({ ...command, response: true }), { flag: "wx", mode: 0o600 });
    await fs.rename(temporary, request);
  } catch (error) {
    await fs.rm(temporary, { force: true });
    throw error;
  }
  for (let i = 0; i < 50; i++) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    try {
      const data: unknown = JSON.parse(await fs.readFile(response, "utf8"));
      await fs.rm(response, { force: true });
      if (!data || typeof data !== "object" || typeof (data as { ok?: unknown }).ok !== "boolean") throw new Error("The tracker sent an invalid response.");
      const result = data as { ok: boolean; error?: string };
      if (!result.ok) throw new Error(result.error || "The tracker could not save the change.");
      return;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  throw new Error("The tracker has not responded. The change is queued and will apply when it is running.");
}

export async function addGroup(input: string): Promise<{ name: string; existing: boolean }> {
  const name = validateName(input);
  const existing = (await groups()).find((item) => normalizeName(item) === normalizeName(name));
  if (existing) return { name: existing, existing: true };
  await sendCommand({ type: "addGroup", name });
  return { name, existing: false };
}

export async function renameGroup(oldInput: string, newInput: string): Promise<void> {
  const oldName = validateName(oldInput);
  const name = validateName(newInput);
  const available = await groups();
  if (!available.some((item) => normalizeName(item) === normalizeName(oldName))) throw new Error("That group no longer exists.");
  if (available.some((item) => normalizeName(item) === normalizeName(name) && normalizeName(item) !== normalizeName(oldName))) throw new Error("A group with that name already exists.");
  await sendCommand({ type: "renameGroup", oldName, name });
}

export async function renameSession(id: string, input: string): Promise<void> {
  if (!/^[a-fA-F0-9-]{36}$/.test(id)) throw new Error("This session could not be identified.");
  await sendCommand({ type: "renameSession", id, name: validateName(input) });
}

export async function selfControlPath(): Promise<string> {
  for (const candidate of [path.join(os.homedir(), "Applications", "SelfControl.app"), "/Applications/SelfControl.app"]) {
    try { await fs.access(candidate); return candidate; } catch { /* Try the next application folder. */ }
  }
  throw new Error("SelfControl was not found in Applications.");
}

export async function deleteGroup(input: string): Promise<void> {
  await sendCommand({ type: "deleteGroup", name: validateName(input) });
}

export async function groupColor(name: string): Promise<number> {
  const colors = (await readArchive()).groupColors;
  const key = Object.keys(colors).find((item) => normalizeName(item) === normalizeName(name));
  if (key && Number.isInteger(colors[key]) && colors[key] >= 0 && colors[key] < 6) return colors[key];
  return [...Buffer.from(name.toLowerCase())].reduce((sum, byte) => (sum + byte) % 6, 0);
}
export async function setGroupColor(name: string, colorIndex: number): Promise<void> {
  await sendCommand({ type: "setGroupColor", name: validateName(name), colorIndex });
}
