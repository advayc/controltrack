import { closeMainWindow, open, showToast, Toast } from "@raycast/api";
import { selfControlPath } from "./lib/storage";

export default async function Command() {
  try {
    await open(await selfControlPath());
    await closeMainWindow();
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "Could not open SelfControl", message: error instanceof Error ? error.message : undefined });
  }
}
