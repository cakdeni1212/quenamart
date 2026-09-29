import type { ReactNode } from "react";
import Link from "next/link";
import type { Profile } from "@/lib/auth/roles";
import { Sidebar } from "@/components/app/sidebar";

export function WorkspaceShell({ profile, children }: { profile: Profile; children: ReactNode }) {
  return <div className="workspace"><Sidebar role={profile.role} name={profile.full_name} /><div className="workspace-main"><header className="mobile-header"><Link className="brand" href="/dashboard"><span className="brand-mark">Q</span><span>quena<span className="brand-light">mart</span></span></Link></header>{children}</div></div>;
}
