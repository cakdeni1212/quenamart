import { redirect } from "next/navigation";
import { HppAcceptanceWorkspace } from "@/components/costing/hpp-acceptance-workspace";
import { canAccessSection } from "@/lib/auth/roles";
import { requireProfile } from "@/lib/auth/session";
import { readHppAcceptanceWorkspace } from "@/lib/costing/hpp-acceptance-read";

type SearchParams = Record<string, string | string[] | undefined>;

export default async function InitialHppPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "hpp-awal")) redirect("/dashboard");
  const data = await readHppAcceptanceWorkspace(await searchParams);

  return <HppAcceptanceWorkspace data={data} role={profile.role} />;
}
