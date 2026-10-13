import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readMemberPage } from "@/lib/members/read.server";
import { MemberWorkspace } from "@/components/members/member-workspace";

export default async function MemberPage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "member")) redirect("/dashboard");
  const data = await readMemberPage();
  return <main className="page-content"><MemberWorkspace initialRows={data.rows} initialTotal={data.total} initialPage={data.page} initialError={data.error} canEdit={profile.role === "OWNER" || profile.role === "ADMIN"} /></main>;
}
