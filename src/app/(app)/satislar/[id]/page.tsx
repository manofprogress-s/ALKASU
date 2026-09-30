import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, Card, PageHeader } from "@/components/ui/card";
import { formatDateTime, formatTRY } from "@/lib/format";
import { SaleActions, type SaleItemForReturn } from "@/components/sales/sale-actions";

const METHOD: Record<string, string> = { nakit: "Nakit", pos: "POS", veresiye: "Veresiye" };

export default async function SaleDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ talep?: string }> }) {
  const ctx = await requirePermission("viewSales");
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data: s } = await supabase
    .from("sales")
    .select(
      "*, customers(id, name), sale_items(id, line_no, unit_name, qty, unit_price, line_gross, line_discount, bill_discount_share, line_net, products(name)), sale_payments(method, amount), sale_deposits(sold_qty, empty_returned, net_containers, amount, products(name)), returns(id, no, created_at, reason, total_refund, return_items(sale_item_id, qty, condition, refund_amount), return_payments(method, amount))",
    )
    .eq("id", id)
    .maybeSingle();
  if (!s) notFound();
  const sale = s as unknown as {
    id: string; no: number; status: string; sold_at: string; created_at: string; goods_gross: number; discount_total: number; goods_net: number;
    deposit_total: number; grand_total: number; change_given: number | null; offline: boolean; late_sync: boolean; limit_override: boolean;
    cancel_reason: string | null; cancelled_at: string | null; session_id: string;
    customers: { id: string; name: string } | null;
    sale_items: { id: string; line_no: number; unit_name: string; qty: number; unit_price: number; line_gross: number; line_discount: number; bill_discount_share: number; line_net: number; products: { name: string } }[];
    sale_payments: { method: string; amount: number }[];
    sale_deposits: { sold_qty: number; empty_returned: number; net_containers: number; amount: number; products: { name: string } }[];
    returns: { id: string; no: number; created_at: string; reason: string; total_refund: number; return_items: { sale_item_id: string; qty: number; condition: string; refund_amount: number }[]; return_payments: { method: string; amount: number }[] }[];
  };
  const items = [...sale.sale_items].sort((a, b) => a.line_no - b.line_no);
  const returned = new Map<string, number>();
  for (const r of sale.returns) for (const ri of r.return_items) returned.set(ri.sale_item_id, (returned.get(ri.sale_item_id) ?? 0) + ri.qty);

  let sessionOpen = false;
  if (ctx.role === "yonetici") {
    const { data: sess } = await supabase.from("cash_sessions").select("status").eq("id", sale.session_id).maybeSingle();
    sessionOpen = sess?.status === "acik";
  }
  let request: { id: string; reason: string; items: unknown } | null = null;
  if (sp.talep) {
    const { data } = await supabase.from("return_requests").select("id, reason, items, status").eq("id", sp.talep).maybeSingle();
    if (data?.status === "bekliyor") request = data;
  }
  const forReturn: SaleItemForReturn[] = items.map((i) => ({
    id: i.id, name: i.products.name, unit: i.unit_name, qty: i.qty, remaining: i.qty - (returned.get(i.id) ?? 0), lineNet: Number(i.line_net),
  }));

  return (
    <div className="space-y-4">
      <PageHeader
        title={`Satış #${sale.no}`}
        subtitle={`${formatDateTime(sale.sold_at)} · ${sale.customers?.name ?? "Perakende müşteri"}`}
        actions={
          <span className="flex gap-1">
            {sale.status === "iptal" ? <Badge tone="danger">İptal edildi</Badge> : <Badge tone="ok">Tamamlandı</Badge>}
            {sale.offline ? <Badge tone="warn">Çevrimdışı satış</Badge> : null}
            {sale.late_sync ? <Badge tone="warn">Geç senkron</Badge> : null}
            {sale.limit_override ? <Badge tone="warn">Limit aşımı onaylı</Badge> : null}
          </span>
        }
      />
      {sale.status === "iptal" ? (
        <Card className="bg-danger-soft text-sm">
          İptal: {formatDateTime(sale.cancelled_at)} · {sale.cancel_reason}
        </Card>
      ) : null}

      <Card className="divide-y divide-border p-0">
        {items.map((i) => (
          <div key={i.id} className="flex items-start justify-between gap-3 p-3">
            <div>
              <div className="font-medium">{i.products.name}</div>
              <div className="num text-xs text-muted">
                {i.qty} {i.unit_name} × {formatTRY(i.unit_price)}
                {Number(i.line_discount) + Number(i.bill_discount_share) > 0 ? ` · indirim ${formatTRY(Number(i.line_discount) + Number(i.bill_discount_share))}` : ""}
                {returned.get(i.id) ? ` · ${returned.get(i.id)} iade` : ""}
              </div>
            </div>
            <div className="num font-medium">{formatTRY(i.line_net)}</div>
          </div>
        ))}
        {sale.sale_deposits.map((d, k) => (
          <div key={k} className="flex justify-between p-3 text-sm">
            <span>
              Depozito · {d.products.name}: {d.sold_qty} satıldı, {d.empty_returned} boş geldi
            </span>
            <span className="num">{formatTRY(d.amount)}</span>
          </div>
        ))}
        <div className="num space-y-1 p-3 text-sm">
          <div className="flex justify-between text-muted"><span>Ara toplam</span><span>{formatTRY(sale.goods_gross)}</span></div>
          {Number(sale.discount_total) > 0 ? <div className="flex justify-between text-muted"><span>İndirim</span><span>−{formatTRY(sale.discount_total)}</span></div> : null}
          {Number(sale.deposit_total) !== 0 ? <div className="flex justify-between text-muted"><span>Depozito</span><span>{formatTRY(sale.deposit_total)}</span></div> : null}
          <div className="flex justify-between text-base font-bold"><span>Toplam</span><span>{formatTRY(sale.grand_total)}</span></div>
          {sale.sale_payments.map((p) => (
            <div key={p.method} className="flex justify-between"><span>{METHOD[p.method]}</span><span>{formatTRY(p.amount)}</span></div>
          ))}
        </div>
      </Card>

      {sale.returns.length > 0 ? (
        <Card>
          <h2 className="mb-2 font-semibold">İadeler</h2>
          <ul className="space-y-2 text-sm">
            {sale.returns.map((r) => (
              <li key={r.id} className="flex justify-between gap-2">
                <span>
                  #{r.no} · {formatDateTime(r.created_at)} · {r.reason}
                  <span className="block text-xs text-muted">{r.return_payments.map((p) => `${METHOD[p.method]} ${formatTRY(p.amount)}`).join(", ")}</span>
                </span>
                <span className="num">−{formatTRY(r.total_refund)}</span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      {sale.status === "tamamlandi" ? (
        <SaleActions
          saleId={sale.id}
          role={ctx.role}
          canCancel={sessionOpen && sale.returns.length === 0}
          hasCustomer={!!sale.customers}
          items={forReturn}
          request={request ? { id: request.id, reason: request.reason } : null}
        />
      ) : null}
    </div>
  );
}
