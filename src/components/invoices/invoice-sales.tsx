import Link from "next/link";
import { formatDate, formatNumber, formatTRY } from "@/lib/format";
import type { InvoiceSaleRef } from "@/lib/invoice";

/** Faturadaki teslimatlar (F-33): satış no, sipariş no, tarih, faturalanan miktar ve tutar */
export function InvoiceSales({ sales, title = "Faturadaki teslimatlar" }: { sales: InvoiceSaleRef[]; title?: string }) {
  if (!sales.length) return null;
  return (
    <div className="rounded-xl border border-border">
      <div className="flex items-center justify-between border-b border-border px-3 py-2 text-sm">
        <span className="font-semibold">{title}</span>
        <span className="text-muted">{sales.length} teslimat</span>
      </div>
      <ul className="divide-y divide-border text-sm">
        {sales.map((s) => (
          <li key={s.id} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 px-3 py-1.5">
            <span className="flex flex-wrap items-center gap-x-2">
              <Link href={`/satislar/${s.id}`} className="font-medium text-brand">Satış #{s.no}</Link>
              {s.order_no ? <span className="text-muted">Sipariş #{s.order_no}</span> : <span className="text-muted">Dükkân satışı</span>}
              <span className="text-muted">{formatDate(s.sold_at)}</span>
              {s.invoiced_by ? <span className="text-danger">zaten faturalanmış</span> : null}
              {s.status !== "tamamlandi" ? <span className="text-danger">iptal</span> : null}
            </span>
            <span className="num text-right">{formatNumber(s.qty)} birim · {formatTRY(s.gross)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
