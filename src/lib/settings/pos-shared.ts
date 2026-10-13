export const POS_PAYMENT_METHODS = ["CASH", "QRIS", "CARD", "E_WALLET"] as const;
export type PosPaymentMethod = (typeof POS_PAYMENT_METHODS)[number];

export type PosSettings = {
  outlet_id: string;
  receipt_footer_note: string | null;
  receipt_show_address: boolean;
  receipt_show_phone: boolean;
  enabled_payment_methods: PosPaymentMethod[];
  allow_hold_transactions: boolean;
  confirm_cart_cancellation: boolean;
  updated_at: string | null;
};

export const DEFAULT_POS_SETTINGS: Omit<PosSettings, "outlet_id" | "updated_at"> = {
  receipt_footer_note: null,
  receipt_show_address: true,
  receipt_show_phone: true,
  enabled_payment_methods: [...POS_PAYMENT_METHODS],
  allow_hold_transactions: true,
  confirm_cart_cancellation: true,
};
