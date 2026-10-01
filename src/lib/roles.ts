export type Role = "yonetici" | "satis" | "depo" | "sevkiyat" | "izleyici" | "bayi";

export const ROLE_LABELS: Record<Role, string> = {
  yonetici: "Yönetici",
  satis: "Satış personeli",
  depo: "Depo personeli",
  sevkiyat: "Sevkiyat / depo yöneticisi",
  izleyici: "İzleyici",
  bayi: "Bayi",
};

export const ROLES = Object.keys(ROLE_LABELS) as Role[];

// BUSINESS_RULES §12, §18 — arayüz tarafı. Asıl kontrol veritabanındadır (Y-01).
// Sevkiyat rolü depo + satış yetkilerinin tümünü kapsar (R-06).
export const PERMISSIONS = {
  sell: ["yonetici", "satis", "sevkiyat"],
  viewSales: ["yonetici", "satis", "sevkiyat"],
  cancelReturn: ["yonetici"],
  customers: ["yonetici", "satis", "sevkiyat"],
  creditLimit: ["yonetici"],
  productEdit: ["yonetici"],
  viewCost: ["yonetici"],
  catalog: ["yonetici", "satis", "depo", "sevkiyat", "izleyici"],
  receiveGoods: ["yonetici", "depo", "sevkiyat"],
  approveCosts: ["yonetici"],
  waste: ["yonetici", "depo", "sevkiyat"],
  count: ["yonetici", "depo", "sevkiyat"],
  approveCount: ["yonetici"],
  cash: ["yonetici"],
  reports: ["yonetici", "izleyici"],
  users: ["yonetici"],
  audit: ["yonetici"],
  orders: ["yonetici", "satis", "sevkiyat", "bayi"],
  orderAssign: ["yonetici", "satis", "sevkiyat"],
  deliver: ["yonetici", "satis", "sevkiyat"],
  myAccount: ["bayi"],
} as const satisfies Record<string, readonly Role[]>;

export type Permission = keyof typeof PERMISSIONS;

export function can(role: Role | null | undefined, p: Permission): boolean {
  return !!role && (PERMISSIONS[p] as readonly Role[]).includes(role);
}

export const PRICE_LISTS = { perakende: "Perakende", bayi: "Bayi", palet: "Palet" } as const;
export type PriceList = keyof typeof PRICE_LISTS;

export const CHANNELS = { perakende: "Perakende", kurumsal: "Kurumsal", bayi: "Bayi" } as const;
export type Channel = keyof typeof CHANNELS;
