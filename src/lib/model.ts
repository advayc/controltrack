export type Session = {
  id: string;
  name: string;
  start: number; // milliseconds since Unix epoch
  plannedEnd: number;
  actualEnd?: number;
};

const APPLE_EPOCH = 978307200;

export function readSession(raw: unknown): Session | null {
  if (!raw || typeof raw !== "object") return null;
  const value = raw as Record<string, unknown>;
  if (
    typeof value.id !== "string" || typeof value.name !== "string" ||
    typeof value.start !== "number" || typeof value.plannedEnd !== "number" ||
    !Number.isFinite(value.start) || !Number.isFinite(value.plannedEnd) ||
    (value.actualEnd != null && (typeof value.actualEnd !== "number" || !Number.isFinite(value.actualEnd)))
  ) return null;
  return {
    id: value.id,
    name: value.name.trim() || "Focus session",
    start: (value.start + APPLE_EPOCH) * 1000,
    plannedEnd: (value.plannedEnd + APPLE_EPOCH) * 1000,
    ...(typeof value.actualEnd === "number" ? { actualEnd: (value.actualEnd + APPLE_EPOCH) * 1000 } : {}),
  };
}

export function endOf(session: Session, now = Date.now()): number {
  return Math.max(session.start, session.actualEnd ?? Math.min(now, session.plannedEnd));
}

export function elapsed(session: Session, now = Date.now()): number {
  return Math.max(0, endOf(session, now) - session.start);
}

export function duration(milliseconds: number): string {
  const minutes = Math.floor(Math.max(0, milliseconds) / 60000);
  const hours = Math.floor(minutes / 60);
  return hours ? `${hours}h ${minutes % 60}m` : `${minutes}m`;
}

export function countdown(milliseconds: number): string {
  const seconds = Math.max(0, Math.ceil(milliseconds / 1000));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = String(seconds % 60).padStart(2, "0");
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${rest}`;
}

export function lastSevenDays(sessions: Session[], now = new Date()): { date: Date; ms: number }[] {
  const today = new Date(now); today.setHours(0, 0, 0, 0);
  return Array.from({ length: 7 }, (_, i) => {
    const start = new Date(today); start.setDate(start.getDate() - (6 - i));
    const end = new Date(start); end.setDate(end.getDate() + 1);
    const ms = sessions.reduce((sum, session) => sum + Math.max(0, Math.min(end.getTime(), endOf(session, now.getTime())) - Math.max(start.getTime(), session.start)), 0);
    return { date: start, ms };
  });
}

export function normalizeName(value: string): string {
  return value.trim().normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase();
}

export function uniqueGroups(names: string[]): string[] {
  const unique = new Map<string, string>();
  for (const name of names) {
    const trimmed = name.trim();
    if (trimmed && normalizeName(trimmed) !== normalizeName("Focus session") && !unique.has(normalizeName(trimmed))) unique.set(normalizeName(trimmed), trimmed);
  }
  return [...unique.values()].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
}

export function groupTotals(sessions: Session[], now = Date.now()): { name: string; ms: number }[] {
  const groups = new Map<string, { name: string; ms: number }>();
  for (const session of sessions) {
    const key = normalizeName(session.name);
    const group = groups.get(key) ?? { name: session.name, ms: 0 };
    group.ms += elapsed(session, now);
    groups.set(key, group);
  }
  return [...groups.values()].sort((a, b) => b.ms - a.ms || a.name.localeCompare(b.name));
}
