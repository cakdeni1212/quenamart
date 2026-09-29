import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { processIposImportRequest } from "@/lib/ipos/worker";

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
  const configuredSecret = process.env.IPOS_IMPORT_WORKER_SECRET;
  if (!configuredSecret || configuredSecret.length < 32) {
    return NextResponse.json({ error: "Worker authorization is not configured." }, { status: 503 });
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
  const requestId = body && typeof body === "object" && "requestId" in body
    ? (body as { requestId?: unknown }).requestId
    : null;
  if (typeof requestId !== "string" || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(requestId)) {
    return NextResponse.json({ error: "A valid requestId is required." }, { status: 400 });
  }

  try {
    const result = await processIposImportRequest(requestId);
    const status = result.result === "COMPLETED" ? 200
      : result.result === "NOT_CLAIMED" ? 404
      : result.result === "ALREADY_PROCESSING" ? 409
      : 200;
    return NextResponse.json(result, { status });
  } catch (error) {
    const message = error instanceof Error ? error.message : "iPos worker failed.";
    return NextResponse.json({ error: message.slice(0, 600) }, { status: 500 });
  }
}
