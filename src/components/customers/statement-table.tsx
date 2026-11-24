"use client";
import { Fragment, useState } from "react";
import { ChevronDown, ChevronRight } from "lucide-react";
import { formatDateTime, formatNumber, formatTRY } from "@/lib/format";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/cn";

export interface StatementRow { at: string; type: string; description: string; debit: number | null; credit: number | null; balance: number; ref_id: string | null }
interface Item { line_no: number; qty: number; unit_name: string; unit_price: number; line_net: number; products: { name: string } | null }
type Detail = Item[] | "loading" | "error";

/** Hesap ekstresi: satış satırına tıklanınca ürün detayı satırın altında açılır (yalnızca açılınca yüklenir). Görünüm DataTable ile aynı. */
export function StatementTable({ rows }: { rows: StatementRow[] }) {
  const [open, setOpen] = useState<Set<number>>(new Set());
  const [details, setDetails] = useState<Record<string, Detail>>({});

  async function toggle(i: number, saleId: string) {
    const next = new Set(open);
    if (next.has(i)) next.delete(i); else next.add(i);
    setOpen(next);
    if (!next.has(i) || (details[saleId] && details[saleId] !== "error")) return;
    setDetails((d) => ({ ...d, [saleId]: "loading" }));
    const { data, error } = await supabaseBrowser().from("sale_items")
      .select("line_no, qty, unit_name, unit_price, line_net, products(name)").eq("sale_id", saleId).order("line_no");
    setDetails((d) => ({ ...d, [saleId]: error ? "error" : ((data ?? []) as unknown as Item[]) }));
  }

  if (rows.length === 0) return <div className="rounded-2xl border border-dashed border-border p-8 text-center text-muted">Hareket yok</div>;

  const isSale = (r: StatementRow) => r.type === "satis" && !!r.ref_id;
  const icon = (i: number) => (open.has(i) ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />);
  const detail = (saleId: string) => {
    const d = details[saleId];
    if (!d || d === "loading") return <p className="py-2 text-sm text-muted">Yükleniyor…</p>;
    if (d === "error") return <p className="py-2 text-sm text-danger">Satış detayı alınamadı. Tekrar açmayı deneyin.</p>;
    if (d.length === 0) return <p className="py-2 text-sm text-muted">Ürün satırı yok</p>;
    return (
      <table className="w-full text-sm">
        <thead className="text-left text-xs text-muted">
          <tr><th className="py-1 pr-2 font-medium">Ürün</th><th className="px-2 py-1 text-right font-medium">Miktar</th><th className="px-2 py-1 text-right font-medium">Birim fiyat</th><th className="py-1 pl-2 text-right font-medium">Toplam</th></tr>
        </thead>
        <tbody>
          {d.map((it) => (
            <tr key={it.line_no}>
              <td className="py-1 pr-2">{it.products?.name ?? "—"}</td>
              <td className="num px-2 py-1 text-right">{formatNumber(it.qty)} {it.unit_name.toLocaleLowerCase("tr-TR")}</td>
              <td className="num px-2 py-1 text-right">{formatTRY(it.unit_price)}</td>
              <td className="num py-1 pl-2 text-right">{formatTRY(it.line_net)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    );
  };

  return (
    <>
      <div className="hidden overflow-x-auto rounded-2xl border border-border bg-surface md:block">
        <table className="w-full text-sm">
          <thead className="bg-surface-2 text-left text-xs text-muted">
            <tr>
              <th className="px-3 py-2 font-medium">Tarih</th>
              <th className="px-3 py-2 font-medium">Açıklama</th>
              <th className="px-3 py-2 text-right font-medium">Borç</th>
              <th className="px-3 py-2 text-right font-medium">Alacak</th>
              <th className="px-3 py-2 text-right font-medium">Bakiye</th>
              <th className="w-8 px-3 py-2" />
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((r, i) => (
              <Fragment key={i}>
                <tr className={cn(isSale(r) && "cursor-pointer hover:bg-surface-2")} onClick={isSale(r) ? () => toggle(i, r.ref_id!) : undefined}
                  aria-expanded={isSale(r) ? open.has(i) : undefined}>
                  <td className="px-3 py-2">{formatDateTime(r.at)}</td>
                  <td className="px-3 py-2">{r.description}</td>
                  <td className="num px-3 py-2 text-right">{r.debit ? formatTRY(r.debit) : ""}</td>
                  <td className="num px-3 py-2 text-right">{r.credit ? formatTRY(r.credit) : ""}</td>
                  <td className="num px-3 py-2 text-right">{formatTRY(r.balance)}</td>
                  <td className="px-3 py-2 text-muted">{isSale(r) ? icon(i) : null}</td>
                </tr>
                {isSale(r) && open.has(i) ? (
                  <tr><td colSpan={6} className="bg-surface-2 px-6 py-2">{detail(r.ref_id!)}</td></tr>
                ) : null}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="space-y-2 md:hidden">
        {rows.map((r, i) => (
          <li key={i} className="rounded-2xl border border-border bg-surface p-3">
            <div className={cn(isSale(r) && "cursor-pointer")} onClick={isSale(r) ? () => toggle(i, r.ref_id!) : undefined}>
              <div className="mb-1 flex items-center justify-between gap-2 font-medium">
                <span>{r.description}</span>{isSale(r) ? <span className="text-muted">{icon(i)}</span> : null}
              </div>
              <dl className="grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
                <dt className="text-muted">Tarih</dt><dd className="text-right">{formatDateTime(r.at)}</dd>
                <dt className="text-muted">Borç</dt><dd className="num text-right">{r.debit ? formatTRY(r.debit) : ""}</dd>
                <dt className="text-muted">Alacak</dt><dd className="num text-right">{r.credit ? formatTRY(r.credit) : ""}</dd>
                <dt className="text-muted">Bakiye</dt><dd className="num text-right">{formatTRY(r.balance)}</dd>
              </dl>
            </div>
            {isSale(r) && open.has(i) ? <div className="mt-2 border-t border-border pt-2">{detail(r.ref_id!)}</div> : null}
          </li>
        ))}
      </ul>
    </>
  );
}
