import { notFound } from "next/navigation";
import { canPrice, requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { loadOrderProducts } from "@/lib/orders";
import { PRICE_LISTS, type PriceList } from "@/lib/roles";
import { PriceEditor, type PeerCustomer } from "@/components/customers/price-editor";

export const metadata = { title: "Özel fiyatlar" };

/** Özel fiyat ekranı (F-38): tüm ürünler tek tabloda, toplu indirim, başka müşteriden kopyalama, tek seferde kaydet */
export default async function CustomerPricesPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("customers");
  const { id } = await params;
  const supabase = await supabaseServer();
  const [{ data: c }, { data: cp }, products, { data: peers }, editable] = await Promise.all([
    supabase.from("customers").select("id, code, name, channel, price_list").eq("id", id).maybeSingle(),
    supabase.from("customer_prices").select("unit_id, price").eq("customer_id", id),
    loadOrderProducts(supabase, ctx.businessId, { includeUnpriced: true }),
    // Hızlı geçiş ve kopyalama için bayi + kurumsal kartlar
    supabase.from("customers").select("id, code, name, channel").eq("business_id", ctx.businessId).eq("active", true)
      .in("channel", ["bayi", "kurumsal"]).order("channel").order("name").limit(500),
    canPrice(),
  ]);
  if (!c) notFound();
  const prices = Object.fromEntries(((cp ?? []) as { unit_id: string; price: number }[]).map((r) => [r.unit_id, Number(r.price)]));
  return (
    <div>
      <PageHeader
        title={`Özel fiyatlar · ${c.name}`}
        subtitle={`${c.code} · normal fiyat: ${PRICE_LISTS[c.price_list as PriceList]} listesi`}
      />
      <PriceEditor
        customer={{ id: c.id, name: c.name, priceList: c.price_list as PriceList }}
        prices={prices}
        products={products}
        peers={((peers ?? []) as PeerCustomer[]).filter((p) => p.id !== c.id)}
        canEdit={editable}
      />
    </div>
  );
}
