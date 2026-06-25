import { cookies } from "next/headers";
import { jwtVerify } from "jose";
import { prisma } from "@/lib/prisma";
import { Sidebar } from "./sidebar";
import { UserProvider } from "./user-provider";
import { CashierGuard } from "./cashier-guard";

const JWT_SECRET = new TextEncoder().encode(
  process.env.JWT_SECRET || "quenamart-secret-key-change-in-production"
);

async function getUser() {
  try {
    const cookieStore = await cookies();
    const token = cookieStore.get("token")?.value;
    if (!token) return null;

    const { payload } = await jwtVerify(token, JWT_SECRET);
    const userId = payload.sub as string;

    const user = await prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, name: true, email: true, role: true },
    });

    return user;
  } catch {
    return null;
  }
}

export async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await getUser();

  if (!user) {
    return (
      <UserProvider initialUser={null}>
        <main className="flex-1">{children}</main>
      </UserProvider>
    );
  }

  return (
    <UserProvider initialUser={user}>
      <div className="flex min-h-full w-full">
        <Sidebar user={user} />
        <main className="flex-1 min-w-0 p-4 lg:p-8 pt-16 lg:pt-8">
          <CashierGuard>{children}</CashierGuard>
        </main>
      </div>
    </UserProvider>
  );
}
