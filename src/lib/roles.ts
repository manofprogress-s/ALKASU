export type Role = "yonetici" | "satis" | "depo" | "sevkiyat" | "izleyici" | "bayi" | "musteri";

export const ROLE_LABELS: Record<Role, string> = {
  yonetici: "Yönetici",
  satis: "Satış personeli",
  depo: "Depo personeli",
  sevkiyat: "Sevkiyat / depo yöneticisi",
  izleyici: "İzleyici",
  bayi: "Bayi",
  musteri: "Müşteri",
};

export const ROLES = Object.keys(ROLE_LABELS) as Role[];
/** Ayarlar'dan oluşturulabilen roller; müşteri kendisi kayıt olur (D-052). */
export const ASSIGNABLE_ROLES = ROLES.filter((r) => r !== "musteri");

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
  expenses: ["yonetici", "satis", "depo", "sevkiyat"], // K-11: personel gider girer, yalnızca kendi girdiğini görür
  profit: ["yonetici"], // GG-01: gelir-gider ve kâr yalnızca yönetici
  reports: ["yonetici"], // G-18: kâr ve dönemsel raporlar yalnızca yönetici
  users: ["yonetici"],
  audit: ["yonetici"],
  orders: ["yonetici", "satis", "sevkiyat", "bayi", "musteri"],
  approveOrders: ["yonetici", "satis", "sevkiyat"],
  routes: ["yonetici", "satis", "sevkiyat", "bayi"],
  orderAssign: ["yonetici", "satis", "sevkiyat"],
  deliver: ["yonetici", "satis", "sevkiyat"],
  myAccount: ["bayi", "musteri"],
  dealerCustomers: ["bayi"],
  invoices: ["yonetici"], // F-21: fatura hazırlama yalnızca yönetici (Logo bağlantısı kurulana kadar)
} as const satisfies Record<string, readonly Role[]>;

export type Permission = keyof typeof PERMISSIONS;

export function can(role: Role | null | undefined, p: Permission): boolean {
  return !!role && (PERMISSIONS[p] as readonly Role[]).includes(role);
}

export const PRICE_LISTS = { perakende: "Gel al", bayi: "Bayi", palet: "Palet", kurumsal: "Kurumsal", ev: "Eve teslim" } as const;
/** Müşteri kartında seçilebilen listeler ("Eve teslim" kart listesi değil; ev müşterisinin siparişlerinde otomatik, F-14) */
export const CUSTOMER_PRICE_LISTS = ["perakende", "kurumsal", "bayi", "palet"] as const;
export type PriceList = keyof typeof PRICE_LISTS;

export const CHANNELS = { perakende: "Ev müşterisi", kurumsal: "Kurumsal", bayi: "Bayi" } as const;
export type Channel = keyof typeof CHANNELS;
