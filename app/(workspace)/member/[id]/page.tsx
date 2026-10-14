import { notFound, redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readMemberDetail } from "@/lib/members/read.server";
import { MemberDetailWorkspace } from "@/components/members/member-detail-workspace";
import QRCode from "qrcode";

export default async function MemberDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "member")) redirect("/dashboard");
  const { id } = await params;
  const data = await readMemberDetail(id);
  if (!data) notFound();
  const member = data.member as Record<string, unknown>;
  const token = typeof member.member_token === "string" ? member.member_token : "";
  const memberCodeImage = token ? await QRCode.toDataURL(token, { errorCorrectionLevel: "M", margin: 2, width: 200, color: { dark: "#25472e", light: "#ffffff" } }) : null;
  const safeMember = { ...member };
  delete safeMember.member_token;
  return <main className="page-content"><MemberDetailWorkspace data={{ ...data, member: safeMember }} memberCodeImage={memberCodeImage} canEdit={profile.role === "OWNER" || profile.role === "ADMIN"} /></main>;
}
