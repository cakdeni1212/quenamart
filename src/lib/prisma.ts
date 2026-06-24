import { PrismaLibSql } from "@prisma/adapter-libsql";
import { PrismaClient } from "@/generated/prisma/client";
import path from "node:path";

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined;
};

const dbPath = path.join(process.cwd(), "dev.db");
const dbUrl = process.env.TURSO_DATABASE_URL ?? process.env.DATABASE_URL ?? `file:${dbPath}`;

export const prisma =
  globalForPrisma.prisma ??
  new PrismaClient({
    adapter: new PrismaLibSql({
      url: dbUrl,
      authToken: process.env.TURSO_AUTH_TOKEN,
    }),
  });

if (process.env.NODE_ENV !== "production") {
  globalForPrisma.prisma = prisma;
}
