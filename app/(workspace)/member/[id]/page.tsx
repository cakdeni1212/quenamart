import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readMemberDetail } from "@/lib/members/read.server";
import { MemberDetailWorkspace } from "@/components/members/member-detail-workspace";

export default async function MemberDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "member")) redirect("/dashboard");
  const { id } = await params;
  const data = await readMemberDetail(id);
  if (!data) notFound();
  return <main className="page-content"><MemberDetailWorkspace data={data} canEdit={profile.role === "OWNER" || profile.role === "ADMIN"} /></main>;
}
