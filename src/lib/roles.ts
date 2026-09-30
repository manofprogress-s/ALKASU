export type Role = "yonetici" | "satis" | "depo" | "izleyici";

export const ROLE_LABELS: Record<Role, string> = {
  yonetici: "Yönetici",
  satis: "Satış personeli",
  depo: "Depo personeli",
  izleyici: "İzleyici",
};

// BUSINESS_RULES §12 — arayüz tarafı. Asıl kontrol veritabanındadır (Y-01).
export const PERMISSIONS = {
  sell: ["yonetici", "satis"],
  viewSales: ["yonetici", "satis"],
  cancelReturn: ["yonetici"],
  customers: ["yonetici", "satis"],
  creditLimit: ["yonetici"],
  productEdit: ["yonetici"],
  viewCost: ["yonetici"],
  receiveGoods: ["yonetici", "depo"],
  approveCosts: ["yonetici"],
  waste: ["yonetici", "depo"],
  count: ["yonetici", "depo"],
  approveCount: ["yonetici"],
  cash: ["yonetici"],
  reports: ["yonetici", "izleyici"],
  users: ["yonetici"],
  audit: ["yonetici"],
} as const satisfies Record<string, readonly Role[]>;

export type Permission = keyof typeof PERMISSIONS;

export function can(role: Role | null | undefined, p: Permission): boolean {
  return !!role && (PERMISSIONS[p] as readonly Role[]).includes(role);
}
