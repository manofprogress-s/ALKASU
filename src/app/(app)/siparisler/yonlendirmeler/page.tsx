import Link from "next/link";
import { redirect } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime } from "@/lib/format";
import { loadAssignees, loadDealers } from "@/lib/orders";

export const metadata = { title: "Sevkiyat yönlendirmeleri" };

interface Row {
  id: number;
  order_id: string;
  from_dealer: string | null;
  to_dealer: string | null;
  special: boolean;
  note: string | null;
  created_by: string | null;
  created_at: string;
  orders: { no: number; customers: { name: string } | null } | null;
}

/** Yönetici: sevkiyat yönlendirme kayıtları (G-17). Varsayılan: özel yönlendirmeler. */
export default async function RoutingLogPage({ searchParams }: { searchParams: Promise<{ tumu?: string }> }) {
  const ctx = await requirePermission("orders");
  if (ctx.role !== "yonetici") redirect("/?yetki=yok");
  const all = (await searchParams).tumu === "1";
  const supabase = await supabaseServer();
  let q = supabase
    .from("order_routing_log")
    .select("id, order_id, from_dealer, to_dealer, special, note, created_by, created_at, orders(no, customers!orders_customer_id_fkey(name))")
    .eq("business_id", ctx.businessId)
    .order("created_at", { ascending: false })
    .limit(200);
  if (!all) q = q.eq("special", true);
  const [{ data }, dealers, people] = await Promise.all([q, loadDealers(supabase, ctx.businessId), loadAssignees(supabase, ctx.businessId)]);
  const dn = new Map(dealers.map((d) => [d.id, d.name]));
  const pn = new Map(people.map((p) => [p.user_id, p.display_name]));
  const where = (id: string | null) => (id ? dn.get(id) ?? "Bayi" : "Depo");
  const rows = (data ?? []) as unknown as Row[];
  const chip = (on: boolean) => `inline-flex h-9 items-center rounded-full border px-3 text-sm ${on ? "border-brand bg-brand-soft text-brand" : "border-border bg-surface"}`;
  return (
    <div className="space-y-4">
      <PageHeader title="Sevkiyat yönlendirmeleri" subtitle="Özel yönlendirmeler sevkiyat sorumlusunun inisiyatifindedir; gerekçesiyle kaydedilir ve değiştirilemez." />
      <div className="flex gap-2">
        <Link href="/siparisler/yonlendirmeler" className={chip(!all)}>Özel yönlendirmeler</Link>
        <Link href="/siparisler/yonlendirmeler?tumu=1" className={chip(all)}>Tümü</Link>
      </div>
      <DataTable rows={rows} rowKey={(r) => String(r.id)} mobileTitle={(r) => `#${r.orders?.no ?? ""} · ${where(r.from_dealer)} → ${where(r.to_dealer)}`}
        columns={[
          { key: "t", label: "Zaman", render: (r) => formatDateTime(r.created_at) },
          { key: "o", label: "Sipariş", render: (r) => <Link className="text-brand" href={`/siparisler/${r.order_id}`}>#{r.orders?.no} {r.orders?.customers?.name ?? ""}</Link> },
          { key: "y", label: "Yönlendirme", hideOnMobile: true, render: (r) => <span>{r.special ? <Badge tone="warn">Özel</Badge> : null} {where(r.from_dealer)} → {where(r.to_dealer)}</span> },
          { key: "k", label: "Yapan", render: (r) => (r.created_by ? pn.get(r.created_by) ?? "—" : "—") },
          { key: "n", label: "Gerekçe", render: (r) => r.note ?? "" },
        ]}
        empty={all ? "Yönlendirme yok" : "Özel yönlendirme yok"} />
    </div>
  );
}
