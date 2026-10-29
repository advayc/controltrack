import { useEffect, useState } from "react";
import { sessions } from "./storage";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const run = promisify(execFile);
import type { Session } from "./model";

export function useSessions() {
  const [data, setData] = useState<Session[]>([]);
  const [isLoading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const [now, setNow] = useState(Date.now());
  const [trackerRunning, setTrackerRunning] = useState<boolean | undefined>();
  async function refresh() {
    try {
      const history = await sessions();
      setData((previous) => JSON.stringify(previous) === JSON.stringify(history) ? previous : history);
      setError(undefined);
      try {
        const { stdout } = await run("/bin/launchctl", ["print", `gui/${process.getuid?.()}/local.focusledger.tracker`]);
        setTrackerRunning(/state = running/.test(stdout));
      } catch { setTrackerRunning(false); }
    }
    catch (err) { setError(err instanceof Error ? err.message : "Could not read session history."); }
    finally { setLoading(false); }
  }
  useEffect(() => {
    void refresh();
    const refreshTimer = setInterval(() => void refresh(), 5000);
    return () => clearInterval(refreshTimer);
  }, []);
  useEffect(() => {
    if (trackerRunning === false || !data.some((session) => session.actualEnd === undefined)) return;
    setNow(Date.now());
    const clock = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(clock);
  }, [data, trackerRunning]);
  return { data, isLoading, error, now, refresh, trackerRunning };
}
