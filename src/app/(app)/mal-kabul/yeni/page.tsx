import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { loadLiteProducts } from "@/lib/products-lite";
import { PurchaseForm } from "@/components/purchases/purchase-form";

export const metadata = { title: "Yeni mal kabul" };

export default async function NewPurchase() {
  const ctx = await requirePermission("receiveGoods");
  const supabase = await supabaseServer();
  const [products, { data: suppliers }] = await Promise.all([
    loadLiteProducts(supabase, ctx.businessId),
    supabase.from("suppliers").select("id, name").eq("business_id", ctx.businessId).eq("active", true).order("name"),
  ]);
  return (
    <div className="space-y-4">
      <PageHeader title="Yeni mal kabul" subtitle={ctx.role === "yonetici" ? "Alış fiyatlarını girerseniz kayıt anında onaylanır" : "Alış fiyatlarını yönetici onaylar"} />
      <PurchaseForm products={products} suppliers={(suppliers ?? []) as { id: string; name: string }[]} />
    </div>
  );
}
