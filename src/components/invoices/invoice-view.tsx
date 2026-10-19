import Link from "next/link";
import { CircleAlert, TriangleAlert } from "lucide-react";
import { formatTRY } from "@/lib/format";
import { TAX_KIND_LABEL, type InvoiceCustomer, type InvoiceIssue, type InvoiceLine, type InvoiceTotals } from "@/lib/invoice";

/** Fatura önizlemesi (F-22): alıcı, satırlar (KDV hariç / KDV / KDV dahil), oran bazında toplam, eksikler */
export function InvoiceView({ customer, lines, totals, issues, docTypeHint }: {
  customer: InvoiceCustomer; lines: InvoiceLine[]; totals: InvoiceTotals; issues: InvoiceIssue[]; docTypeHint?: string;
}) {
  const errors = issues.filter((i) => i.level === "error");
  const warnings = issues.filter((i) => i.level === "warning");
  const fixHref = customer.id ? `/musteriler/${customer.id}?fatura=1#fatura-bilgileri` : null;
  const place = [customer.address, customer.district, customer.city].filter(Boolean).join(", ");
  return (
    <div className="space-y-3">
      {errors.length || warnings.length ? (
        <div className="space-y-1.5">
          {errors.map((i, k) => (
            <p key={`e${k}`} className="flex items-start gap-1.5 rounded-lg bg-danger-soft px-2.5 py-1.5 text-sm text-danger">
              <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" /> <span>{i.message}</span>
            </p>
          ))}
          {warnings.map((i, k) => (
            <p key={`w${k}`} className="flex items-start gap-1.5 rounded-lg bg-warn-soft px-2.5 py-1.5 text-sm text-warn">
              <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" /> <span>{i.message}</span>
            </p>
          ))}
          {fixHref && issues.some((i) => ["tax_no", "tax_office", "legal_title", "address", "city", "email"].includes(i.field)) ? (
            <Link href={fixHref} className="inline-block text-sm font-medium text-brand">Müşterinin fatura bilgilerini tamamla →</Link>
          ) : null}
        </div>
      ) : null}

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="rounded-xl border border-border p-3 text-sm">
          <div className="text-xs font-medium uppercase tracking-wide text-muted">Alıcı</div>
          <div className="mt-1 font-semibold">{customer.legal_title ?? customer.name}</div>
          {customer.legal_title && customer.legal_title !== customer.name ? <div className="text-muted">{customer.name}</div> : null}
          <div className="text-muted">
            {TAX_KIND_LABEL[customer.kind]}{customer.tax_no ? `: ${customer.tax_no}` : ""}{customer.tax_office ? ` · ${customer.tax_office} VD` : ""}
          </div>
          {place ? <div className="text-muted">{place}</div> : null}
          {customer.email ? <div className="text-muted">{customer.email}</div> : null}
        </div>
        <div className="rounded-xl border border-border p-3 text-sm">
          <div className="text-xs font-medium uppercase tracking-wide text-muted">Belge türü</div>
          <div className="mt-1">{docTypeHint ?? "Logo İşbaşı belirleyecek"}</div>
          <div className="mt-1 text-xs text-muted">Kesin tür ve fatura numarası Logo İşbaşı’ndan gelecek.</div>
        </div>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border">
        <table className="w-full min-w-[560px] text-sm">
          <thead className="bg-surface-2 text-xs text-muted">
            <tr>
              <th className="px-2.5 py-2 text-left font-medium">Ürün</th>
              <th className="px-2.5 py-2 text-right font-medium">Miktar</th>
              <th className="px-2.5 py-2 text-right font-medium">Birim fiyat (KDV hariç)</th>
              <th className="px-2.5 py-2 text-right font-medium">KDV</th>
              <th className="px-2.5 py-2 text-right font-medium">Tutar (KDV hariç)</th>
              <th className="px-2.5 py-2 text-right font-medium">KDV dahil</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {lines.map((l) => (
              <tr key={l.line_no}>
                <td className="px-2.5 py-2">
                  <div className="font-medium">{l.name}</div>
                  <div className="text-xs text-muted">{l.product_code}{Number(l.discount) > 0 ? ` · indirim ${formatTRY(Number(l.discount))} (KDV dahil)` : ""}</div>
                </td>
                <td className="num px-2.5 py-2 text-right">{l.qty} {l.unit}</td>
                <td className="num px-2.5 py-2 text-right">{formatTRY(Number(l.unit_price_net))}</td>
                <td className="num px-2.5 py-2 text-right">%{l.vat_rate}</td>
                <td className="num px-2.5 py-2 text-right">{formatTRY(Number(l.net))}</td>
                <td className="num px-2.5 py-2 text-right font-medium">{formatTRY(Number(l.gross))}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="ml-auto max-w-sm space-y-1 text-sm">
        <div className="num flex justify-between"><span className="text-muted">Toplam (KDV hariç)</span><span>{formatTRY(Number(totals.net))}</span></div>
        {totals.by_rate.map((r) => (
          <div key={r.rate} className="num flex justify-between">
            <span className="text-muted">KDV %{r.rate} <span className="text-xs">({formatTRY(Number(r.net))} üzerinden)</span></span>
            <span>{formatTRY(Number(r.vat))}</span>
          </div>
        ))}
        <div className="num flex justify-between border-t border-border pt-1 text-base font-bold"><span>Fatura toplamı</span><span>{formatTRY(Number(totals.gross))}</span></div>
        {Number(totals.deposit) !== 0 ? (
          <div className="num flex justify-between text-xs text-muted"><span>Depozito (faturaya eklenmedi)</span><span>{formatTRY(Number(totals.deposit))}</span></div>
        ) : null}
      </div>
    </div>
  );
}
