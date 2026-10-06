import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, PageHeader } from "@/components/ui/card";
import { RoutePlanner, type RouteOrder } from "@/components/orders/route-planner";
import { loadAssignees, type Assignee } from "@/lib/orders";
import { toLatLng, type LatLng } from "@/lib/geo";
import { todayISO } from "@/lib/format";

export const metadata = { title: "Rota" };

interface Row {
  id: string;
  no: number;
  delivery_date: string;
  address: string | null;
  assignee: string | null;
  customers: { name: string; phone: string | null; latitude: number | null; longitude: number | null } | null;
  order_items: { qty: number; product_units: { name: string } | null; products: { name: string } | null }[];
}

/**
 * Rota (D-056): açık siparişleri başlangıç noktasından en kısa sıraya dizer.
 * Personel: depo konumundan, seçilen kişiye atanmış (veya henüz atanmamış) siparişler.
 * Bayi: kendi depo konumundan, kendisine atanmış ev müşterisi siparişleri.
 */
export default async function RoutePage({ searchParams }: { searchParams: Promise<{ kim?: string; gun?: string }> }) {
  const ctx = await requirePermission("routes");
  const sp = await searchParams;
  const isDealer = ctx.role === "bayi";
  const day = sp.gun && /^\d{4}-\d{2}-\d{2}$/.test(sp.gun) ? sp.gun : todayISO();
  const kim = isDealer ? "bayi" : sp.kim ?? ctx.userId; // kullanıcı kimliği | "atanmamis" | "hepsi"
  const supabase = await supabaseServer();

  let q = supabase
    .from("orders")
    .select("id, no, delivery_date, address, assignee, customers!orders_customer_id_fkey(name, phone, latitude, longitude), order_items(qty, product_units(name), products(name))")
    .eq("business_id", ctx.businessId)
    .eq("status", "acik")
    .lte("delivery_date", day)
    .order("delivery_date")
    .limit(200);
  if (isDealer) q = q.eq("dealer_customer_id", ctx.customerId ?? "");
  else {
    q = q.is("dealer_customer_id", null);
    if (kim === "atanmamis") q = q.is("assignee", null);
    else if (kim !== "hepsi") q = q.eq("assignee", kim);
  }

  const [{ data }, startRes, assignees] = await Promise.all([
    q,
    isDealer
      ? supabase.from("customers").select("latitude, longitude").eq("id", ctx.customerId ?? "").maybeSingle()
      : supabase.from("locations").select("latitude, longitude").eq("id", ctx.locationId).maybeSingle(),
    isDealer ? Promise.resolve([] as Assignee[]) : loadAssignees(supabase, ctx.businessId),
  ]);
  const start: LatLng | null = toLatLng(startRes.data?.latitude, startRes.data?.longitude);
  const orders: RouteOrder[] = ((data ?? []) as unknown as Row[]).map((o) => ({
    id: o.id,
    no: o.no,
    customer: o.customers?.name ?? "",
    phone: o.customers?.phone ?? null,
    address: o.address,
    late: o.delivery_date < day,
    point: toLatLng(o.customers?.latitude, o.customers?.longitude),
    summary: o.order_items.map((i) => `${i.qty} ${i.product_units?.name ?? ""} ${i.products?.name ?? ""}`).join(", "),
  }));

  return (
    <div className="space-y-4">
      <PageHeader title="Rota" subtitle={isDealer ? "Size atanan teslimatlar, deponuzdan en kısa sırayla" : "Açık siparişler, depodan en kısa sırayla"} />
      {!start ? (
        <Alert tone="warn">
          Başlangıç noktası (depo konumu) girilmemiş.{" "}
          {isDealer ? <Link href="/hesabim" className="font-semibold underline">Hesabım → konum</Link>
            : ctx.role === "yonetici" ? <Link href="/ayarlar" className="font-semibold underline">Ayarlar → Depo konumu</Link>
              : "Yöneticinizden Ayarlar'da depo konumunu girmesini isteyin."}
        </Alert>
      ) : null}
      <RoutePlanner
        start={start}
        orders={orders}
        day={day}
        who={kim}
        people={isDealer ? [] : assignees.map((a) => ({ id: a.user_id, name: a.display_name }))}
        me={ctx.userId}
        canChooseWho={!isDealer}
        businessId={ctx.businessId}
      />
    </div>
  );
}
