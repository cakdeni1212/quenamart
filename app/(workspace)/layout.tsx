import type { ReactNode } from "react";
import { WorkspaceShell } from "@/components/app/workspace-shell";
import { requireProfile } from "@/lib/auth/session";

export default async function WorkspaceLayout({ children }: { children: ReactNode }) {
  const profile = await requireProfile();
  return <WorkspaceShell profile={profile}>{children}</WorkspaceShell>;
}
