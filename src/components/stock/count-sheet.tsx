"use client";
import { useMemo, useState } from "react";
import { CheckCircle2, Clock } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Input } from "@/components/ui/field";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { useRpc } from "@/lib/use-action";
import { searchKey } from "@/lib/catalog";
import { formatNumber } from "@/lib/format";

export interface CountLine {
  productId: string; name: string; code: string; baseUnit: string;
  units: { id: string; name: string; factor: number }[];
  snapshot: number; counted: number | null; diff: number | null;
}

/** Birim karışık giriş: ör. 3 koli + 5 şişe → temel birime çevrilir. */
interface PreviewLine { product_id: string; name: string; unit: string; system: number; counted: number; diff: number }

export function CountSheet({ countId, status, lines, canApprove, decidedText }: {
  countId: string; status: string; lines: CountLine[]; canApprove: boolean; decidedText?: string | null;
}) {
  const { call, busy } = useRpc();
  const toast = useToast();
  const [preview, setPreview] = useState<PreviewLine[] | null>(null);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [q, setQ] = useState("");
  const [parts, setParts] = useState<Record<string, Record<string, string>>>({});
  const [dirty, setDirty] = useState<Set<string>>(new Set());
  const open = status === "acik";

  const total = (l: CountLine): number | null => {
    const p = parts[l.productId];
    if (!p) return l.counted;
    const vals = Object.entries(p).filter(([, v]) => v !== "");
    if (vals.length === 0) return null;
    return vals.reduce((s, [k, v]) => s + (parseInt(v, 10) || 0) * (k === "base" ? 1 : l.units.find((u) => u.id === k)?.factor ?? 1), 0);
  };
  const setPart = (pid: string, key: string, v: string) => {
    setParts((x) => ({ ...x, [pid]: { ...(x[pid] ?? {}), [key]: v.replace(/\D/g, "") } }));
    setDirty((d) => new Set(d).add(pid));
  };

  const shown = useMemo(() => {
    const k = searchKey(q.trim());
    return lines.filter((l) => !k || searchKey(`${l.name} ${l.code}`).includes(k));
  }, [lines, q]);
  const countedN = lines.filter((l) => total(l) !== null).length;

  async function save(): Promise<boolean> {
    const payload = [...dirty].map((pid) => ({ product_id: pid, counted_qty: total(lines.find((l) => l.productId === pid)!) }));
    if (payload.length === 0) return true;
    const ok = await call("save_stock_count_lines", { p_count: countId, p_lines: payload }, { success: canApprove ? "Sayım kaydedildi" : "Sayım kaydedildi · yönetici onayı bekleniyor" });
    if (ok) setDirty(new Set());
    return !!ok;
  }

  // Onay öncesi: kaydedilmemiş girişleri kaydet, farkları göster (T-04)
  async function openApprove() {
    if (!(await save())) return;
    const { data, error } = await supabaseBrowser().rpc("stock_count_preview", { p_count: countId });
    if (error) return toast(errorMessage(error), "danger");
    setPreview(((data as { lines: PreviewLine[] }).lines ?? []));
  }

  async function approve() {
    const ok = await call("approve_stock_count", { p_count: countId }, { success: "Sayım onaylandı, farklar stoğa işlendi" });
    if (ok) setPreview(null);
  }
  const changed = preview?.filter((l) => l.diff !== 0) ?? [];

  return (
    <div className="space-y-3">
      {status === "onaylandi" ? (
        <Alert tone="ok"><span className="flex items-center gap-1.5"><CheckCircle2 className="h-4 w-4 shrink-0" /> Stoğa işlendi{decidedText ? ` · ${decidedText}` : ""}. Bu sayım kilitli; tekrar uygulanamaz.</span></Alert>
      ) : status === "iptal" ? (
        <Alert tone="neutral">Bu sayım iptal edildi; stok değişmedi.</Alert>
      ) : (
        <Alert tone={countedN ? "warn" : "brand"}>
          <span className="flex items-start gap-1.5">
            <Clock className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              <b>Stoğa henüz işlenmedi.</b> {countedN} / {lines.length} ürün sayıldı.{" "}
              {canApprove
                ? "Sayım bitince “Onayla ve stoğa işle”ye basın; farklar o anda stoğa yansır. Boş bırakılan ürünlerin stoğu değişmez."
                : "Girdiğiniz miktarlar kaydedilir; stok, yönetici onayladığında güncellenir."}
            </span>
          </span>
        </Alert>
      )}
      <Input placeholder="Ürün ara" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="space-y-2">
        {shown.map((l) => {
          const t = total(l);
          return (
            <Card key={l.productId} className="p-3">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="font-medium">{l.name}</div>
                  <div className="text-xs text-muted">Sayım başında sistem: {formatNumber(l.snapshot)} {l.baseUnit.toLocaleLowerCase("tr-TR")}</div>
                </div>
                <div className="text-right">
                  {t !== null ? <div className="num font-semibold">{formatNumber(t)}</div> : <Badge>Sayılmadı</Badge>}
                  {l.diff !== null ? <div className={`num text-xs ${l.diff < 0 ? "text-danger" : l.diff > 0 ? "text-ok" : "text-muted"}`}>Fark {l.diff > 0 ? "+" : ""}{l.diff}</div> : null}
                </div>
              </div>
              {open ? (
                <div className="mt-2 flex flex-wrap gap-2">
                  {l.units.map((u) => (
                    <label key={u.id} className="flex items-center gap-1 text-sm">
                      <Input className="h-10 w-20" inputMode="numeric" value={parts[l.productId]?.[u.id] ?? ""} onChange={(e) => setPart(l.productId, u.id, e.target.value)} />
                      {u.name}
                    </label>
                  ))}
                  <label className="flex items-center gap-1 text-sm">
                    <Input className="h-10 w-20" inputMode="numeric" value={parts[l.productId]?.base ?? (parts[l.productId] ? "" : l.counted?.toString() ?? "")} onChange={(e) => setPart(l.productId, "base", e.target.value)} />
                    {l.baseUnit}
                  </label>
                </div>
              ) : null}
            </Card>
          );
        })}
      </div>
      {open ? (
        <div className="safe-bottom sticky bottom-20 flex flex-wrap gap-2 rounded-2xl bg-bg py-2 md:bottom-0">
          <Button className="flex-1" variant={canApprove ? "secondary" : "primary"} loading={busy} disabled={dirty.size === 0} onClick={() => void save()}>Kaydet ({dirty.size})</Button>
          {canApprove ? (
            <>
              <Button variant="ok" className="flex-1" loading={busy} disabled={countedN === 0} onClick={() => void openApprove()}>
                Onayla ve stoğa işle
              </Button>
              <Button variant="ghost" onClick={() => setCancelOpen(true)}>İptal</Button>
            </>
          ) : null}
        </div>
      ) : null}

      <Dialog open={!!preview} onClose={() => setPreview(null)} title="Sayımı onayla"
        footer={<Button variant="ok" className="w-full" loading={busy} onClick={() => void approve()}>Onayla, {changed.length} ürünün stoğunu güncelle</Button>}>
        <div className="space-y-2 text-sm">
          <p className="text-muted">Sayılan {preview?.length ?? 0} ürün. Onaydan sonra sayım kilitlenir; aynı sayım ikinci kez uygulanamaz.</p>
          {changed.length ? (
            <ul className="divide-y divide-border rounded-xl border border-border">
              {changed.map((l) => (
                <li key={l.product_id} className="flex items-center justify-between gap-2 px-3 py-2">
                  <span>{l.name}</span>
                  <span className="num text-right">
                    {formatNumber(l.system)} → <b>{formatNumber(l.counted)}</b> {l.unit.toLocaleLowerCase("tr-TR")}
                    <span className={`ml-2 ${l.diff < 0 ? "text-danger" : "text-ok"}`}>{l.diff > 0 ? "+" : ""}{l.diff}</span>
                  </span>
                </li>
              ))}
            </ul>
          ) : <Alert tone="ok">Sayılan ürünlerde fark yok; stok değişmeyecek, sayım kapanacak.</Alert>}
        </div>
      </Dialog>
      <Dialog open={cancelOpen} onClose={() => setCancelOpen(false)} title="Sayımı iptal et"
        footer={<Button variant="danger" className="w-full" loading={busy} onClick={async () => { if (await call("cancel_stock_count", { p_count: countId }, { success: "Sayım iptal edildi" })) setCancelOpen(false); }}>İptal et</Button>}>
        <p className="text-sm">Girilen miktarlar stoğa işlenmeden sayım kapatılır.</p>
      </Dialog>
    </div>
  );
}
