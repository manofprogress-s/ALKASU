import Link from "next/link";
import { ClipboardList, MapPin } from "lucide-react";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Badge, Card, PageHeader } from "@/components/ui/card";
import { formatDate, formatTRY } from "@/lib/format";
import { ORDER_STATUS, type OrderStatus } from "@/lib/orders";

interface Row {
  id: string;
  no: number;
  delivery_date: string;
  status: OrderStatus;
  dealer_customer_id: string | null;
  order_items: { qty: number; unit_price: number; products: { name: string } | null; product_units: { name: string } | null }[];
}

/** Müşteri (internetten kayıtlı) ana sayfası: yeni sipariş ve son siparişler */
export async function CustomerHome({ name, welcome, orderNo, warning }: { name: string; welcome: boolean; orderNo?: string; warning?: string }) {
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("orders")
    .select("id, no, delivery_date, status, dealer_customer_id, order_items(qty, unit_price, products(name), product_units(name))")
    .order("created_at", { ascending: false })
    .limit(10);
  const rows = (data ?? []) as unknown as Row[];
  return (
    <div className="space-y-4">
      <PageHeader title={`Merhaba, ${name}`} />
      {welcome && orderNo ? (
        <Alert tone="ok">Siparişiniz alındı (No: {orderNo}). İlk siparişinizi telefonla teyit edip yola çıkaracağız.</Alert>
      ) : null}
      {warning ? <Alert tone="warn">{warning}</Alert> : null}
      <Link href="/siparisler/yeni" className="flex items-center justify-center gap-3 rounded-2xl bg-brand p-5 text-lg font-semibold text-white shadow-sm active:scale-[0.99]">
        <ClipboardList className="h-6 w-6" /> Yeni sipariş
      </Link>
      <Card className="space-y-2">
        <h2 className="font-semibold">Siparişlerim</h2>
        {rows.length === 0 ? <p className="text-sm text-muted">Henüz siparişiniz yok.</p> : null}
        <ul className="divide-y divide-border">
          {rows.map((o) => (
            <li key={o.id}>
              <Link href={`/siparisler/${o.id}`} className="flex items-center justify-between gap-2 py-2">
                <span className="min-w-0">
                  <span className="block text-sm font-medium">
                    #{o.no} · {formatDate(o.delivery_date)}
                  </span>
                  <span className="line-clamp-1 text-xs text-muted">
                    {o.order_items.map((i) => `${i.qty} ${i.product_units?.name ?? ""} ${i.products?.name ?? ""}`).join(", ")}
                  </span>
                </span>
                <span className="flex shrink-0 flex-col items-end gap-1">
                  <Badge tone={o.status === "teslim_edildi" ? "ok" : o.status === "iptal" ? "neutral" : o.status === "onay_bekliyor" ? "warn" : "brand"}>
                    {o.status === "acik" && o.dealer_customer_id ? "Yolda" : ORDER_STATUS[o.status]}
                  </Badge>
                  <span className="num text-xs">{formatTRY(o.order_items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0))}</span>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      </Card>
      <Link href="/hesabim" className="flex items-center gap-2 text-sm text-brand">
        <MapPin className="h-4 w-4" /> Adresimi ve konumumu güncelle
      </Link>
    </div>
  );
}
