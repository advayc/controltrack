import { randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { normalizeName, readSession, uniqueGroups, type Session } from "./model";

export const root = path.join(os.homedir(), "Library", "Application Support", "Focus Ledger");
const archivePath = path.join(root, "sessions.json");
const groupPath = path.join(root, "groups");
const commandPath = path.join(root, "commands");

export async function sessions(): Promise<Session[]> {
  let data: string;
  try { data = await fs.readFile(archivePath, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  const parsed: unknown = JSON.parse(data);
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as { sessions?: unknown }).sessions)) throw new Error("The session history is not in the expected format.");
  const rawSessions = (parsed as { sessions: unknown[] }).sessions;
  const result = rawSessions.map(readSession);
  if (result.some((session) => session === null)) throw new Error("A session in the history is not in the expected format.");
  return (result as Session[]).sort((a, b) => b.start - a.start);
}

export async function groups(history?: Session[]): Promise<string[]> {
  const stored: string[] = [];
  let files: string[];
  try { files = await fs.readdir(groupPath); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    files = [];
  }
  for (const file of files.filter((name) => name.endsWith(".json"))) {
    try {
      const value: unknown = JSON.parse(await fs.readFile(path.join(groupPath, file), "utf8"));
      if (typeof value === "string") stored.push(value);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return uniqueGroups([...stored, ...(history ?? await sessions()).map((session) => session.name)]);
}

export function validateName(input: string): string {
  const name = input.trim();
  if (!name) throw new Error("Enter a subject or group.");
  if (name.length > 120 || /[\r\n\u0000-\u001f]/.test(name)) throw new Error("Use a single line of at most 120 characters.");
  if (normalizeName(name) === normalizeName("Focus session")) throw new Error("Choose a name other than the default ‘Focus session’.");
  return name;
}

export async function addGroup(input: string): Promise<{ name: string; existing: boolean }> {
  const name = validateName(input);
  const existing = (await groups()).find((item) => normalizeName(item) === normalizeName(name));
  if (existing) return { name: existing, existing: true };
  await fs.mkdir(groupPath, { recursive: true });
  await fs.writeFile(path.join(groupPath, `${randomUUID()}.json`), JSON.stringify(name), { flag: "wx", mode: 0o600 });
  return { name, existing: false };
}

export async function renameSession(id: string, input: string): Promise<void> {
  if (!/^[a-fA-F0-9-]{36}$/.test(id)) throw new Error("This session could not be identified.");
  const name = validateName(input);
  await fs.mkdir(commandPath, { recursive: true });
  const file = path.join(commandPath, `${randomUUID()}.json`);
  await fs.writeFile(file, JSON.stringify({ type: "renameSession", id, name }), { flag: "wx", mode: 0o600 });
  for (let i = 0; i < 50; i++) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    try { await fs.access(file); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  }
  throw new Error("The tracker has not responded. The change is queued and will apply when it is running.");
}

export async function selfControlPath(): Promise<string> {
  for (const candidate of [path.join(os.homedir(), "Applications", "SelfControl.app"), "/Applications/SelfControl.app"]) {
    try { await fs.access(candidate); return candidate; } catch { /* Try the next application folder. */ }
  }
  throw new Error("SelfControl was not found in Applications.");
}
