export type MemberPointsSettings = {
  outlet_id: string;
  program_enabled: boolean;
  rupiah_per_point: string | null;
  redeem_enabled: boolean;
  rupiah_per_redeem_point: string | null;
  minimum_redeem_points: string | null;
  updated_at: string | null;
};

export type MemberPointsSettingsInput = Omit<MemberPointsSettings, "outlet_id" | "updated_at">;
