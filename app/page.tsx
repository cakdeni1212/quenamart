import { redirect } from "next/navigation";
import { getProfile } from "@/lib/auth/session";
import { landingPathForRole } from "@/lib/auth/roles";

export default async function HomePage() {
  const profile = await getProfile();
  redirect(profile ? landingPathForRole(profile.role) : "/login");
}
