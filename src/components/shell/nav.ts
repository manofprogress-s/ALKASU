import type { Permission } from "@/lib/roles";

export interface NavItem {
  href: string;
  label: string;
  icon: string;
  perm?: Permission;
  mobile?: boolean; // alt çubukta göster
}

export const NAV: NavItem[] = [
  { href: "/", label: "Ana sayfa", icon: "home", mobile: true },
  { href: "/satis", label: "Satış", icon: "cart", perm: "sell", mobile: true },
  { href: "/satislar", label: "Satışlar", icon: "receipt", perm: "viewSales" },
  { href: "/stok", label: "Stok", icon: "boxes", mobile: true },
  { href: "/musteriler", label: "Müşteriler", icon: "users", perm: "customers", mobile: true },
  { href: "/mal-kabul", label: "Mal kabul", icon: "truck", perm: "receiveGoods" },
  { href: "/urunler", label: "Ürünler", icon: "tag" },
  { href: "/kasa", label: "Kasa", icon: "wallet", perm: "cash" },
  { href: "/raporlar", label: "Raporlar", icon: "chart", perm: "reports" },
  { href: "/ayarlar", label: "Ayarlar", icon: "settings", perm: "users" },
];
