import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, PageHeader } from "@/components/ui/card";
import { ShopLayoutEditor } from "@/components/shop/shop-layout-editor";
import { toShopItems, type CatalogRow } from "@/lib/shop";

export const metadata = { title: "Mağaza düzeni" };

/** Yönetici: müşteri sipariş ekranındaki ürünleri gizle / sırala / değiştir (W-11) */
export default async function ShopLayoutPage() {
  const ctx = await requirePermission("productEdit");
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("shop_catalog_admin", { p_business: ctx.businessId });
  const items = toShopItems((data ?? []) as CatalogRow[]);
  return (
    <div className="mx-auto max-w-2xl">
      <PageHeader title="Mağaza düzeni" subtitle="Müşterinin sipariş ekranında hangi ürün nerede görünsün"
        actions={<Link href="/urunler" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Ürünler</Link>} />
      {error ? <Alert>{error.message}</Alert> : items.length === 0 ? (
        <Alert tone="warn">Fiyatı girilmiş aktif ürün yok. Ürünler’den fiyat girin.</Alert>
      ) : <ShopLayoutEditor initial={items} />}
    </div>
  );
}
