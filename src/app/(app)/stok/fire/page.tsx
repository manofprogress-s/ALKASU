import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { loadLiteProducts } from "@/lib/products-lite";
import { WasteForm } from "@/components/stock/waste-form";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatNumber } from "@/lib/format";

export const metadata = { title: "Fire / hasar" };
const REASONS: Record<string, string> = { kirik: "Kırık", sizinti: "Sızıntı", skt: "SKT geçmiş", kayip: "Kayıp / çalıntı", iade_kusurlu: "Kusurlu iade", diger: "Diğer" };

export default async function WastePage() {
  const ctx = await requirePermission("waste");
  const supabase = await supabaseServer();
  const [products, { data }] = await Promise.all([
    loadLiteProducts(supabase, ctx.businessId),
    supabase.from("waste_records").select("id, qty, base_qty, reason, note, created_at, products(name, base_unit_name), product_units(name)")
      .eq("business_id", ctx.businessId).order("created_at", { ascending: false }).limit(100),
  ]);
  const rows = (data ?? []) as unknown as { id: string; qty: number; base_qty: number; reason: string; note: string | null; created_at: string; products: { name: string; base_unit_name: string }; product_units: { name: string } | null }[];
  return (
    <div className="space-y-4">
      <PageHeader title="Fire / hasar" />
      <WasteForm products={products} />
      <h2 className="font-semibold">Son kayıtlar</h2>
      <DataTable rows={rows} rowKey={(r) => r.id} mobileTitle={(r) => r.products.name}
        columns={[
          { key: "t", label: "Zaman", render: (r) => formatDateTime(r.created_at) },
          { key: "p", label: "Ürün", hideOnMobile: true, render: (r) => r.products.name },
          { key: "q", label: "Miktar", align: "right", render: (r) => `${formatNumber(r.qty)} ${r.product_units?.name ?? r.products.base_unit_name}` },
          { key: "r", label: "Neden", render: (r) => REASONS[r.reason] ?? r.reason },
          { key: "n", label: "Not", render: (r) => r.note ?? "" },
        ]} />
    </div>
  );
}
