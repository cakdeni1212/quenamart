import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { runIposPreflight } from "@/lib/ipos/preflight";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: NextRequest, configuredSecret: string) {
  const authorization = request.headers.get("authorization") ?? "";
  const suppliedSecret = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  const expected = Buffer.from(configuredSecret);
  const supplied = Buffer.from(suppliedSecret);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export async function POST(request: NextRequest) {
  const configuredSecret = process.env.IPOS_PREFLIGHT_SECRET;
  if (!configuredSecret || configuredSecret.length < 32) {
    return NextResponse.json({ error: "Preflight authorization is not configured." }, { status: 503 });
  }
  if (!authorized(request, configuredSecret)) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Expected a JSON request body." }, { status: 400 });
  }
  const batchId = body && typeof body === "object" && "batchId" in body
    ? (body as { batchId?: unknown }).batchId
    : null;
  if (typeof batchId !== "string" || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(batchId)) {
    return NextResponse.json({ error: "A valid batchId is required." }, { status: 400 });
  }

  try {
    const report = await runIposPreflight(batchId);
    return NextResponse.json(report, {
      headers: { "Cache-Control": "no-store, max-age=0" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "iPos preflight failed.";
    const status = message.includes("not found") ? 404
      : message.includes("requires a COMPLETED") || message.includes("invariants") ? 409
      : 500;
    return NextResponse.json({ error: message.slice(0, 500) }, {
      status,
      headers: { "Cache-Control": "no-store, max-age=0" },
    });
  }
}
