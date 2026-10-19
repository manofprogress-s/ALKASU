import { Card } from "@/components/ui/card";
import { formatDateTime, formatTRY } from "@/lib/format";
import { formatPhone } from "@/lib/username";
import { OUTCOME_LABEL } from "@/lib/customer-status";

export interface CallRow { called_at: string; outcome: string; note: string | null; next_call_on: string | null; user_id: string }

interface CustomerFields {
  legacy_no: number | null;
  segment: string | null;
  district: string | null;
  area: string | null;
  address_note: string | null;
  brand_pref: string | null;
  preferred_product: string | null;
  extra_phones: string[] | null;
  legacy_registered_at: string | null;
  legacy_last_sale_at: string | null;
  legacy_order_count: number | null;
  legacy_total_sales: number | null;
  legacy_period_days: number | null;
  legacy_debt: number | null;
}

/** Müşteri kartında saha bilgisi, eski sistem geçmişi ve arama geçmişi (M-20, M-25) */
export function FieldHistory({ c, isAdmin, calls, names }: { c: CustomerFields; isAdmin: boolean; calls: CallRow[]; names: Record<string, string> }) {
  const facts: [string, string][] = [];
  if (c.legacy_no) facts.push(["Abone no (eski sistem)", String(c.legacy_no)]);
  if (c.segment) facts.push(["Tür", c.segment === "isyeri" ? "İşyeri" : "Ev"]);
  if (c.area) facts.push(["Saha / bölge", c.area]);
  if (c.district) facts.push(["İlçe", c.district]);
  if (c.address_note) facts.push(["Adres tarifi", c.address_note]);
  if (c.brand_pref) facts.push(["Kullandığı marka", c.brand_pref]);
  if (c.preferred_product) facts.push(["Tercih ettiği ürün", c.preferred_product]);
  if (c.extra_phones?.length) facts.push(["Diğer telefonlar", c.extra_phones.map(formatPhone).join(", ")]);
  if (c.legacy_registered_at) facts.push(["Kayıt", c.legacy_registered_at.split("-").reverse().join(".")]);
  if (c.legacy_last_sale_at) facts.push(["Son alım (eski sistem)", formatDateTime(c.legacy_last_sale_at)]);
  if (c.legacy_order_count) facts.push(["Sipariş sayısı (eski sistem)", String(c.legacy_order_count)]);
  if (c.legacy_period_days) facts.push(["Alım aralığı", `~${c.legacy_period_days} gün`]);
  if (isAdmin && c.legacy_total_sales) facts.push(["Toplam satış (eski sistem)", formatTRY(c.legacy_total_sales)]);
  if (isAdmin && c.legacy_debt) facts.push(["Eski sistem borcu (listedeki)", formatTRY(c.legacy_debt)]);
  if (!facts.length && !calls.length) return null;
  return (
    <Card className="space-y-3">
      {facts.length ? (
        <>
          <h2 className="font-semibold">Saha bilgisi</h2>
          <dl className="grid gap-x-4 gap-y-1 text-sm sm:grid-cols-2">
            {facts.map(([k, v]) => (
              <div key={k} className="flex justify-between gap-3 border-b border-border/60 py-1">
                <dt className="text-muted">{k}</dt>
                <dd className="text-right font-medium">{v}</dd>
              </div>
            ))}
          </dl>
        </>
      ) : null}
      {calls.length ? (
        <>
          <h2 className="font-semibold">Arama geçmişi</h2>
          <ul className="divide-y divide-border text-sm">
            {calls.map((k) => (
              <li key={k.called_at} className="py-1.5">
                <span className="font-medium">{OUTCOME_LABEL[k.outcome] ?? k.outcome}</span>
                <span className="text-muted"> · {names[k.user_id] ?? "Kullanıcı"} · {formatDateTime(k.called_at)}</span>
                {k.note ? <div className="text-muted">“{k.note}”</div> : null}
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </Card>
  );
}
