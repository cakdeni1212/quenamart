export function normalizeWhatsAppDestination(value: unknown): { e164: string; chatId: string } | null;
export function sendManualWhatsAppTest(input: {
  role: string;
  actorId: string;
  destination: unknown;
  message: unknown;
  provider: { sendManualTestMessage(chatId: string, text: string): Promise<unknown> } | (() => { sendManualTestMessage(chatId: string, text: string): Promise<unknown> });
  now?: number;
}): Promise<{ ok: boolean; message: string }>;
