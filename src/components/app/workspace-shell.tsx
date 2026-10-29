import type { ReactNode } from "react";
import type { Profile } from "@/lib/auth/roles";
import { WorkspaceFrame } from "@/components/app/workspace-frame";

export function WorkspaceShell({ profile, children }: { profile: Profile; children: ReactNode }) {
  return <div className="workspace"><WorkspaceFrame role={profile.role} name={profile.full_name}>{children}</WorkspaceFrame></div>;
}
