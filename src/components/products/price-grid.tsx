"use client";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { FileSpreadsheet, Save } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatTRY, parseAmount } from "@/lib/format";
import { searchKey } from "@/lib/catalog";
import { readWorkbook } from "@/lib/excel/read";
import { downloadXlsx } from "@/lib/excel/write";

export interface PriceRow {
  unitId: string;
  code: string;
  product: string;
  unit: string;
  factor: number;
  perakende: number | null;
  bayi: number | null;
  palet: number | null;
}

type Col = "perakende" | "bayi" | "palet";
const COLS: Col[] = ["perakende", "bayi", "palet"];
const str = (n: number | null) => (n === null ? "" : String(n).replace(".", ","));

interface Issue { row: number; field: string; message: string }

export function PriceGrid({ rows }: { rows: PriceRow[] }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [issues, setIssues] = useState<Issue[]>([]);

  const key = (r: PriceRow, c: Col) => `${r.unitId}:${c}`;
  const shown = useMemo(() => {
    const k = searchKey(q.trim());
    return k ? rows.filter((r) => searchKey(`${r.code} ${r.product}`).includes(k)) : rows;
  }, [rows, q]);

  const changes = useMemo(() => {
    const out: { row: PriceRow; col: Col; value: number | null }[] = [];
    for (const r of rows)
      for (const c of COLS) {
        const e = edits[key(r, c)];
        if (e === undefined) continue;
        const v = e.trim() === "" ? null : parseAmount(e);
        if (e.trim() !== "" && (v === null || v < 0)) continue;
        if (v !== r[c]) out.push({ row: r, col: c, value: v });
      }
    return out;
  }, [edits, rows]);
  const invalid = Object.entries(edits).some(([, e]) => e.trim() !== "" && (parseAmount(e) === null || (parseAmount(e) ?? 0) < 0));

  async function save() {
    setBusy(true);
    setError(null);
    const sb = supabaseBrowser();
    try {
      // Dolu değerler tek işlemde (import_prices); silinen bayi/palet fiyatları tek tek
      const byUnit = new Map<string, Record<string, string>>();
      for (const ch of changes) {
        if (ch.value === null) continue;
        const r = byUnit.get(ch.row.unitId) ?? { row: "0", urun_kodu: ch.row.code, birim: ch.row.unit };
        r[`${ch.col}_fiyati`] = String(ch.value);
        byUnit.set(ch.row.unitId, r);
      }
      if (byUnit.size) {
        const { error } = await sb.rpc("import_prices", { p_business: ctx.businessId, p_rows: [...byUnit.values()], p_dry_run: false });
        if (error) throw error;
      }
      for (const ch of changes.filter((c) => c.value === null)) {
        if (ch.col === "perakende") continue; // perakende fiyat buradan silinmez
        const { error } = await sb.rpc("set_list_price", { p_unit: ch.row.unitId, p_list: ch.col, p_price: null });
        if (error) throw error;
      }
      toast(`${changes.length} fiyat kaydedildi`, "ok");
      setEdits({});
      router.refresh();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function exportXlsx() {
    await downloadXlsx(
      rows.map((r) => ({
        urun_kodu: r.code,
        urun_adi: r.product,
        birim: r.unit,
        perakende_fiyati: r.perakende,
        bayi_fiyati: r.bayi,
        palet_fiyati: r.palet,
      })),
      "fiyat_listesi",
      "Fiyatlar",
    );
  }

  async function importFile(f: File) {
    setBusy(true);
    setError(null);
    setIssues([]);
    try {
      const wb = await readWorkbook(f);
      const sheet = Object.values(wb).find((s) => s.length && "urun_kodu" in s[0]!) ?? [];
      if (!sheet.length) throw new Error("Dosyada 'urun_kodu' sütunu olan bir sayfa bulunamadı. Önce 'Excel'e aktar' ile şablonu indirin.");
      const sb = supabaseBrowser();
      const dry = await sb.rpc("import_prices", { p_business: ctx.businessId, p_rows: sheet, p_dry_run: true });
      if (dry.error) throw dry.error;
      const res = dry.data as { ok: boolean; errors: Issue[]; summary: { rows: number } };
      if (!res.ok) {
        setIssues(res.errors);
        throw new Error("Dosyada hata var; hiçbir fiyat kaydedilmedi (E-01).");
      }
      if (!confirm(`${res.summary.rows} satır fiyat güncellenecek. Onaylıyor musunuz?`)) return;
      const run = await sb.rpc("import_prices", { p_business: ctx.businessId, p_rows: sheet, p_dry_run: false });
      if (run.error) throw run.error;
      toast("Fiyat listesi içe aktarıldı", "ok");
      router.refresh();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-center gap-2">
        <Input className="max-w-xs" placeholder="Ürün ara" value={q} onChange={(e) => setQ(e.target.value)} />
        <Button variant="secondary" onClick={() => void exportXlsx()}>
          <FileSpreadsheet className="h-4 w-4" /> Excel&apos;e aktar
        </Button>
        <label className="inline-flex h-11 cursor-pointer items-center gap-2 rounded-xl border border-border bg-surface px-4 hover:bg-surface-2">
          <FileSpreadsheet className="h-4 w-4" /> Excel&apos;den yükle
          <input type="file" accept=".xlsx,.csv" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ""; if (f) void importFile(f); }} />
        </label>
        <Button className="ml-auto" onClick={() => void save()} loading={busy} disabled={changes.length === 0 || invalid}>
          <Save className="h-4 w-4" /> Kaydet {changes.length ? `(${changes.length})` : ""}
        </Button>
      </div>
      {error ? <Alert>{error}</Alert> : null}
      {issues.length ? (
        <Alert>
          <ul className="list-inside list-disc">
            {issues.slice(0, 30).map((i, n) => <li key={n}>Satır {i.row}: {i.message}</li>)}
          </ul>
        </Alert>
      ) : null}
      <Card className="overflow-x-auto p-0">
        <table className="w-full min-w-[640px] text-sm">
          <thead className="bg-surface-2 text-left text-muted">
            <tr>
              <th className="px-3 py-2">Ürün</th>
              <th className="px-3 py-2">Birim</th>
              <th className="px-3 py-2 text-right">Perakende ₺</th>
              <th className="px-3 py-2 text-right">Bayi ₺</th>
              <th className="px-3 py-2 text-right">Palet ₺</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {shown.map((r) => (
              <tr key={r.unitId}>
                <td className="px-3 py-1.5">
                  <div className="font-medium">{r.product}</div>
                  <div className="text-xs text-muted">{r.code}</div>
                </td>
                <td className="px-3 py-1.5">{r.unit}{r.factor > 1 ? <span className="text-xs text-muted"> ({r.factor})</span> : null}</td>
                {COLS.map((c) => {
                  const k = key(r, c);
                  const val = edits[k] ?? str(r[c]);
                  const bad = val.trim() !== "" && (parseAmount(val) === null || (parseAmount(val) ?? 0) < 0);
                  return (
                    <td key={c} className="px-2 py-1.5">
                      <Input
                        inputMode="decimal"
                        className={`num h-9 w-28 text-right ${edits[k] !== undefined ? "border-brand" : ""} ${bad ? "border-danger" : ""}`}
                        placeholder={c === "perakende" ? "—" : r.perakende !== null ? formatTRY(r.perakende) : "—"}
                        value={val}
                        onChange={(e) => setEdits((x) => ({ ...x, [k]: e.target.value }))}
                      />
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </div>
  );
}
