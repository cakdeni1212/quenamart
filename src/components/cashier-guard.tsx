"use client";

import { useEffect } from "react";
import { useRouter, usePathname } from "next/navigation";
import { useUser } from "./user-provider";

const cashierAllowed = ["/minimarket", "/suppliers", "/tempo"];

export function CashierGuard({ children }: { children: React.ReactNode }) {
  const { user, loading } = useUser();
  const router = useRouter();
  const pathname = usePathname();

  useEffect(() => {
    if (loading) return;
    if (user?.role === "cashier") {
      const allowed = cashierAllowed.some((p) => pathname === p || pathname.startsWith(p + "/"));
      if (!allowed) {
        router.replace("/minimarket");
      }
    }
  }, [user, loading, pathname, router]);

  if (loading) return null;
  return <>{children}</>;
}
