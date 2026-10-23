"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { ArrowRight, ClipboardPaste, FileSpreadsheet, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card, Stat } from "@/components/ui/card";
import { Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { readWorkbook } from "@/lib/excel/read";
import {
import { ChipBar, ChipCount, chipClass } from "@/components/ui/chips";
  MATCH_STATUS, logoFirmsFromSheet, parseLogoPaste, plannedFills, taxConflict,
  type LogoFirm, type MatchResult, type MatchStatus,
} from "@/lib/logo-firms";

interface Preview { results: MatchResult[]; duplicates: { vkn: string; codes: string[] }[] }
interface ApplyResult { linked: number; filled: number; errors: { code: string; name?: string; message: string }[]; warnings: { code: string; name?: string; message: string }[] }

const CHUNK = 400;
const ORDER: MatchStatus[] = ["kesin", "olasi", "coklu", "yok", "bagli"];

/** İşbaşı cari listesi → ALKASU kart eşleştirme (F-28). Önce önizleme; yalnızca onaylanan satırlar bağlanır. */
export function LogoFirms() {
  const ctx = useAppContext();
  const toast = useToast();
  const [text, setText] = useState("");
  const [firms, setFirms] = useState<LogoFirm[] | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [choice, setChoice] = useState<Record<string, string>>({}); // İşbaşı kodu → seçilen kart id ("" = bağlama)
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<ApplyResult | null>(null);
  const [open, setOpen] = useState<MatchStatus | null>(null);

  async function check(list: LogoFirm[]) {
    setError(null); setDone(null);
    if (!list.length) {
      setError("Liste okunamadı. İşbaşı’ndaki müşteri listesini başlık satırıyla birlikte (Müşteri Kodu, Müşteri Ünvanı …) kopyalayın.");
      return;
    }
    setBusy(true);
    try {
      const acc: Preview = { results: [], duplicates: [] };
      for (let i = 0; i < list.length; i += CHUNK) {
        const { data, error } = await supabaseBrowser().rpc("logo_firms_preview", { p_business: ctx.businessId, p_rows: list.slice(i, i + CHUNK) });
        if (error) throw error;
        const p = data as Preview;
        acc.results.push(...p.results);
        acc.duplicates.push(...p.duplicates);
      }
      setFirms(list);
      setPreview(acc);
      // Kesin eşleşmeler hazır seçili; olası ve çoklu satırlar kullanıcı onayı bekler
      const c: Record<string, string> = {};
      for (const r of acc.results) { const id = r.candidates[0]?.id; if (r.status === "kesin" && id) c[r.code] = id; }
      setChoice(c);
      setOpen(acc.results.some((r) => r.status === "olasi" || r.status === "coklu") ? "olasi" : "kesin");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function pickFile(f: File) {
    if (/\.xls$/i.test(f.name)) {
      setError("Bu dosya eski Excel biçiminde (.xls). Excel’de “Farklı kaydet → Excel Çalışma Kitabı (.xlsx)” ile kaydedip tekrar seçin ya da tabloyu kopyalayıp yapıştırın.");
      return;
    }
    try {
      const wb = await readWorkbook(f);
      await check(logoFirmsFromSheet(Object.values(wb)[0] ?? []));
    } catch (e) {
      setError(errorMessage(e));
    }
  }

  const byCode = useMemo(() => new Map((firms ?? []).map((f) => [f.code, f])), [firms]);
  const groups = useMemo(() => {
    const g: Record<MatchStatus, MatchResult[]> = { bagli: [], kesin: [], olasi: [], coklu: [], yok: [] };
    for (const r of preview?.results ?? []) g[r.status].push(r);
    return g;
  }, [preview]);
  const selected = Object.entries(choice).filter(([, id]) => id);

  async function apply() {
    if (!selected.length) return;
    setBusy(true);
    try {
      const links = selected.map(([code, customer]) => ({ customer, firm: byCode.get(code) }));
      const acc: ApplyResult = { linked: 0, filled: 0, errors: [], warnings: [] };
      for (let i = 0; i < links.length; i += CHUNK) {
        const { data, error } = await supabaseBrowser().rpc("logo_firms_apply", { p_business: ctx.businessId, p_links: links.slice(i, i + CHUNK) });
        if (error) throw error;
        const r = data as ApplyResult;
        acc.linked += r.linked; acc.filled += r.filled; acc.errors.push(...r.errors); acc.warnings.push(...r.warnings);
      }
      setDone(acc);
      toast(`${acc.linked} müşteri İşbaşı’na bağlandı`, "ok");
      if (firms) await check(firms); // güncel durumu yeniden göster
      setDone(acc);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  if (!preview) {
    return (
      <Card className="space-y-3">
        <div>
          <h2 className="font-semibold">1. İşbaşı müşteri listesini ekleyin</h2>
          <p className="text-sm text-muted">
            İşbaşı → Müşteriler listesini Excel’e aktarın. Tablonun tamamını (başlık satırı dahil) kopyalayıp aşağıya yapıştırın ya da .xlsx dosyasını seçin.
            Bu adım hiçbir şeyi değiştirmez; sadece eşleşmeleri gösterir.
          </p>
        </div>
        <Textarea rows={8} value={text} onChange={(e) => setText(e.target.value)} placeholder={"Müşteri Kodu\tTipi\t…\tMüşteri Ünvanı\t…\tMüşteri Vkn - Tckn\tVergi Dairesi\t…"}
          className="font-mono text-xs" spellCheck={false} />
        <div className="flex flex-wrap gap-2">
          <Button loading={busy} disabled={!text.trim()} onClick={() => void check(parseLogoPaste(text))}>
            <ClipboardPaste className="h-4 w-4" /> Yapıştırılanı kontrol et
          </Button>
          <label className="inline-flex h-11 cursor-pointer items-center gap-2 rounded-xl border border-border bg-surface px-4 font-medium hover:bg-surface-2">
            <FileSpreadsheet className="h-4 w-4" /> Excel dosyası seç
            <input type="file" accept=".xlsx,.xls" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; if (f) void pickFile(f); e.target.value = ""; }} />
          </label>
        </div>
        {error ? <Alert>{error}</Alert> : null}
      </Card>
    );
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-2 md:grid-cols-5">
        <Stat label="Kesin eşleşme" value={groups.kesin.length} hint="vergi no aynı" tone="ok" />
        <Stat label="Olası" value={groups.olasi.length} hint="onayınız gerekli" tone={groups.olasi.length ? "warn" : undefined} />
        <Stat label="Birden fazla aday" value={groups.coklu.length} hint="kart seçin" tone={groups.coklu.length ? "warn" : undefined} />
        <Stat label="ALKASU’da yok" value={groups.yok.length} />
        <Stat label="Zaten bağlı" value={groups.bagli.length} />
      </div>

      {done ? (
        <Alert tone="ok">
          {done.linked} kart bağlandı, {done.filled} kartta boş fatura bilgileri dolduruldu.
          {done.errors.length ? ` ${done.errors.length} satır bağlanamadı (aşağıda).` : ""}
        </Alert>
      ) : null}
      {done && (done.errors.length || done.warnings.length) ? (
        <Card className="space-y-1 text-sm">
          {done.errors.map((e, i) => <p key={`e${i}`} className="text-danger">{e.name ?? e.code}: {e.message}</p>)}
          {done.warnings.map((e, i) => <p key={`w${i}`} className="text-warn">{e.name ?? e.code}: {e.message}</p>)}
        </Card>
      ) : null}

      {preview.duplicates.length ? (
        <Alert tone="warn">
          <span className="flex items-start gap-1.5">
            <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              İşbaşı’nda aynı vergi numarasıyla birden fazla cari var: {preview.duplicates.map((d) => `${d.vkn} (${d.codes.map((c) => c.replace(/^0+/, "")).join(", ")})`).join(" · ")}.
              Bir karta yalnızca biri bağlanabilir; diğerini İşbaşı’nda birleştirmeniz önerilir.
            </span>
          </span>
        </Alert>
      ) : null}

      <ChipBar>
        {ORDER.map((k) => (
          <button key={k} type="button" onClick={() => setOpen(k)} className={chipClass(open === k)}>
            {MATCH_STATUS[k].label}<ChipCount n={groups[k].length} />
          </button>
        ))}
      </ChipBar>
      {open ? <p className="text-sm text-muted">{MATCH_STATUS[open].hint}</p> : null}

      <ul className="space-y-2">
        {(open ? groups[open] : []).map((r) => {
          const firm = byCode.get(r.code);
          const sel = choice[r.code] ?? "";
          const cand = r.candidates.find((c) => c.id === sel) ?? (r.candidates.length === 1 ? r.candidates[0] : undefined);
          const fills = firm && cand ? plannedFills(firm, cand, r.vkn_ok) : [];
          const conflict = firm && cand ? taxConflict(firm, cand) : false;
          const selectable = r.status !== "bagli" && r.status !== "yok";
          return (
            <li key={r.code}>
              <Card className="space-y-2 p-3">
                <div className="flex flex-wrap items-start gap-3">
                  {selectable && r.candidates.length === 1 ? (
                    <input type="checkbox" className="mt-1 h-5 w-5 accent-brand" checked={!!sel} aria-label="Bağla"
                      onChange={(e) => setChoice((c) => ({ ...c, [r.code]: e.target.checked ? (r.candidates[0]?.id ?? "") : "" }))} />
                  ) : null}
                  <div className="min-w-0 flex-1">
                    <div className="font-medium">{r.unvan}</div>
                    <div className="text-xs text-muted">
                      İşbaşı kodu {r.code.replace(/^0+/, "")}
                      {r.vkn ? <> · {r.vkn.length === 11 ? "TCKN" : "VKN"} {r.vkn}</> : " · vergi no yok"}
                      {r.vkn && !r.vkn_ok ? <Badge tone="danger" className="ml-1">geçersiz numara</Badge> : null}
                      {firm?.vd ? <> · {firm.vd}</> : null}
                    </div>
                  </div>
                  {r.reason ? <Badge tone={MATCH_STATUS[r.status].tone}>{r.reason}</Badge> : null}
                </div>

                {r.status === "coklu" ? (
                  <div className="space-y-1 pl-8">
                    {r.candidates.map((c) => (
                      <label key={c.id} className="flex items-center gap-2 text-sm">
                        <input type="radio" name={`c-${r.code}`} checked={sel === c.id} onChange={() => setChoice((x) => ({ ...x, [r.code]: c.id }))} />
                        <span>{c.name} <span className="text-muted">({c.code}{c.phone ? ` · ${c.phone}` : ""}{c.tax_no ? ` · ${c.tax_no}` : ""})</span></span>
                      </label>
                    ))}
                    <label className="flex items-center gap-2 text-sm text-muted">
                      <input type="radio" name={`c-${r.code}`} checked={!sel} onChange={() => setChoice((x) => ({ ...x, [r.code]: "" }))} /> Hiçbiri / şimdilik bağlama
                    </label>
                  </div>
                ) : null}

                {cand && r.status !== "coklu" ? (
                  <div className="flex flex-wrap items-center gap-1.5 pl-8 text-sm">
                    <ArrowRight className="h-4 w-4 text-muted" />
                    <Link href={`/musteriler/${cand.id}`} className="font-medium text-brand" target="_blank">{cand.name}</Link>
                    <span className="text-muted">({cand.code}{cand.phone ? ` · ${cand.phone}` : ""})</span>
                  </div>
                ) : null}
                {cand && r.status !== "bagli" ? (
                  <p className="pl-8 text-xs text-muted">
                    {fills.length ? <>Bağlanınca doldurulacak: <b className="text-text">{fills.join(", ")}</b></> : "Kartta doldurulacak boş alan yok; yalnızca İşbaşı kodu kaydedilir."}
                    {conflict ? <span className="block text-warn">Kartta farklı vergi no var ({cand.tax_no}); değiştirilmeyecek.</span> : null}
                  </p>
                ) : null}
              </Card>
            </li>
          );
        })}
        {open && !groups[open].length ? <li className="rounded-2xl border border-dashed border-border p-6 text-center text-muted">Bu grupta kayıt yok</li> : null}
      </ul>

      <div className="sticky bottom-3 z-10 flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-border bg-surface p-3 shadow-lg">
        <span className="text-sm">
          <b className="num">{selected.length}</b> kart bağlanacak
          <span className="block text-xs text-muted">Yalnızca boş alanlar doldurulur; dolu bilgiye ve bakiyeye dokunulmaz.</span>
        </span>
        <span className="flex gap-2">
          <Button variant="ghost" onClick={() => { setPreview(null); setFirms(null); setDone(null); }}>Yeni liste</Button>
          <Button loading={busy} disabled={!selected.length} onClick={() => void apply()}>Seçilenleri bağla</Button>
        </span>
      </div>
      {error ? <Alert>{error}</Alert> : null}
    </div>
  );
}
