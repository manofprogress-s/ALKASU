"use client";
import { useMemo, useState } from "react";
import { CheckCircle2, Clock, Copy, MessageCircle, Send, Undo2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { useRpc } from "@/lib/use-action";
import { searchKey } from "@/lib/catalog";
import { formatDateTime, formatNumber } from "@/lib/format";
import { countReportText, diffSentence, type CountDiffLine } from "@/lib/stock-count";

export interface CountLine {
  productId: string; name: string; code: string; baseUnit: string;
  units: { id: string; name: string; factor: number }[];
  snapshot: number; counted: number | null; diff: number | null;
}

export interface CountApprovalInfo {
  required: number;
  approvals: { user_id: string; name: string | null; at: string }[];
  approvers: { user_id: string; name: string }[];
  submittedBy: string | null;
  submittedAt: string | null;
  summary: CountDiffLine[] | null;
}

/** Fark raporu: her ürün için önce / sayılan / eklenen-çıkarılan (T-04/6) */
function DiffReport({ lines }: { lines: CountDiffLine[] }) {
  const changed = lines.filter((l) => l.diff !== 0);
  if (!lines.length) return <p className="text-sm text-muted">Sayılan ürün yok.</p>;
  return (
    <div className="space-y-2">
      <p className="text-sm text-muted">{lines.length} ürün sayıldı, {changed.length} üründe fark var. Farksız ürünler stokta aynı kalır.</p>
      <ul className="divide-y divide-border rounded-xl border border-border text-sm">
        {lines.map((l) => (
          <li key={l.product_id} className={`space-y-0.5 px-3 py-2 ${l.diff === 0 ? "text-muted" : ""}`}>
            <div className="font-medium text-text">{l.name}</div>
            <div className="num grid grid-cols-2 gap-x-3 text-xs sm:grid-cols-3">
              <span>Sayımdan önce: <b>{formatNumber(l.system)}</b></span>
              <span>Güncel sayım: <b>{formatNumber(l.counted)}</b> {l.unit.toLocaleLowerCase("tr-TR")}</span>
              <span className={l.diff < 0 ? "text-danger" : l.diff > 0 ? "text-ok" : ""}>{diffSentence(l)}</span>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Birim karışık giriş: ör. 3 koli + 5 şişe → temel birime çevrilir. Akış: sayılıyor → onaya gönder → 2 yönetici onayı → stoğa işlenir. */
export function CountSheet({ countId, countNo, status, lines, isAdmin, decidedText, approval }: {
  countId: string; countNo: number; status: string; lines: CountLine[]; isAdmin: boolean; decidedText?: string | null; approval: CountApprovalInfo;
}) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const toast = useToast();
  const [submitPreview, setSubmitPreview] = useState<CountDiffLine[] | null>(null);
  const [approveOpen, setApproveOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reopenOpen, setReopenOpen] = useState(false);
  const [reopenNote, setReopenNote] = useState("");
  const [q, setQ] = useState("");
  const [parts, setParts] = useState<Record<string, Record<string, string>>>({});
  const [dirty, setDirty] = useState<Set<string>>(new Set());
  const open = status === "acik";
  const pending = status === "onayda";
  const iApproved = approval.approvals.some((a) => a.user_id === ctx.userId);
  const report = approval.summary ?? [];

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
    const ok = await call("save_stock_count_lines", { p_count: countId, p_lines: payload }, { success: "Sayım kaydedildi" });
    if (ok) setDirty(new Set());
    return !!ok;
  }

  // Onaya göndermeden önce: kaydedilmemiş girişleri kaydet, fark raporunu göster
  async function openSubmit() {
    if (!(await save())) return;
    const { data, error } = await supabaseBrowser().rpc("stock_count_preview", { p_count: countId });
    if (error) return toast(errorMessage(error), "danger");
    setSubmitPreview(((data as { lines: CountDiffLine[] }).lines ?? []));
  }
  async function submit() {
    const ok = await call("submit_stock_count", { p_count: countId }, { success: "Sayım yönetim onayına gönderildi" });
    if (ok) setSubmitPreview(null);
  }
  async function approve() {
    const r = await call<{ applied: boolean; approvals: number; required: number }>("approve_stock_count", { p_count: countId });
    if (!r) return;
    setApproveOpen(false);
    toast(r.applied ? "Sayım onaylandı, farklar stoğa işlendi" : `Onayınız kaydedildi (${r.approvals}/${r.required}). Diğer yöneticinin onayı bekleniyor.`, "ok");
  }

  const text = countReportText(countNo, report, { by: approval.submittedBy, onlyChanged: report.length > 15 });
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      toast("Rapor kopyalandı", "ok");
    } catch {
      toast("Kopyalanamadı; metni seçip kopyalayın", "danger");
    }
  }

  return (
    <div className="space-y-3">
      {status === "onaylandi" ? (
        <Alert tone="ok"><span className="flex items-center gap-1.5"><CheckCircle2 className="h-4 w-4 shrink-0" /> Stoğa işlendi{decidedText ? ` · ${decidedText}` : ""}. Bu sayım kilitli; tekrar uygulanamaz.</span></Alert>
      ) : status === "iptal" ? (
        <Alert tone="neutral">Bu sayım iptal edildi; stok değişmedi.</Alert>
      ) : pending ? (
        <Alert tone="warn">
          <span className="flex items-start gap-1.5">
            <Clock className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              <b>Yönetim onayında · stoğa henüz işlenmedi.</b>{" "}
              {approval.submittedBy ? `${approval.submittedBy} ` : ""}{approval.submittedAt ? `${formatDateTime(approval.submittedAt)} tarihinde ` : ""}onaya gönderdi.
              Stok, {approval.required} yönetici onayından sonra güncellenir.
            </span>
          </span>
        </Alert>
      ) : (
        <Alert tone={countedN ? "warn" : "brand"}>
          <span className="flex items-start gap-1.5">
            <Clock className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              <b>Sayılıyor · stoğa henüz işlenmedi.</b> {countedN} / {lines.length} ürün sayıldı.
              Sayım bitince “Onaya gönder”e basın; fark raporu yönetime gider, {approval.required} yönetici onayından sonra stok güncellenir. Boş bırakılan ürünlerin stoğu değişmez.
            </span>
          </span>
        </Alert>
      )}

      {pending ? (
        <Card className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="font-semibold">Fark raporu</h2>
            <div className="flex flex-wrap gap-1.5">
              {approval.approvers.map((a) => {
                const ok = approval.approvals.some((x) => x.user_id === a.user_id);
                return <Badge key={a.user_id} tone={ok ? "ok" : "neutral"}>{a.name}: {ok ? "onayladı" : "bekliyor"}</Badge>;
              })}
            </div>
          </div>
          <DiffReport lines={report} />
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="secondary" onClick={() => void copy()}><Copy className="h-4 w-4" /> Raporu kopyala</Button>
            <a className="inline-flex h-9 items-center gap-1.5 rounded-xl border border-border bg-surface px-3 text-sm font-medium"
              href={`https://wa.me/?text=${encodeURIComponent(text)}`} target="_blank" rel="noreferrer">
              <MessageCircle className="h-4 w-4" /> WhatsApp’ta paylaş
            </a>
          </div>
          {isAdmin ? (
            <div className="flex flex-wrap gap-2 border-t border-border pt-3">
              <Button variant="ok" className="flex-1" disabled={iApproved} loading={busy} onClick={() => setApproveOpen(true)}>
                {iApproved ? `Onayladınız (${approval.approvals.length}/${approval.required})` : `Onayla (${approval.approvals.length + 1}/${approval.required})`}
              </Button>
              <Button variant="secondary" onClick={() => setReopenOpen(true)}><Undo2 className="h-4 w-4" /> Düzeltme için geri gönder</Button>
              <Button variant="ghost" onClick={() => setCancelOpen(true)}>İptal</Button>
            </div>
          ) : null}
        </Card>
      ) : null}

      {!pending ? <Input placeholder="Ürün ara" value={q} onChange={(e) => setQ(e.target.value)} /> : null}
      {!pending ? (
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
      ) : null}
      {open ? (
        <div className="safe-bottom sticky bottom-20 flex flex-wrap gap-2 rounded-2xl bg-bg py-2 md:bottom-0">
          <Button className="flex-1" variant="secondary" loading={busy} disabled={dirty.size === 0} onClick={() => void save()}>Kaydet ({dirty.size})</Button>
          <Button className="flex-1" loading={busy} disabled={countedN === 0} onClick={() => void openSubmit()}><Send className="h-4 w-4" /> Onaya gönder</Button>
          {isAdmin ? <Button variant="ghost" onClick={() => setCancelOpen(true)}>İptal</Button> : null}
        </div>
      ) : null}

      <Dialog open={!!submitPreview} onClose={() => setSubmitPreview(null)} title={`Sayım #${countNo} · onaya gönder`} wide
        footer={<Button className="w-full" loading={busy} onClick={() => void submit()}><Send className="h-4 w-4" /> Yönetim onayına gönder</Button>}>
        <div className="space-y-2">
          <DiffReport lines={submitPreview ?? []} />
          <p className="text-xs text-muted">Gönderdikten sonra girişler kilitlenir. Yönetim düzeltme isterse sayım size geri döner.</p>
        </div>
      </Dialog>
      <Dialog open={approveOpen} onClose={() => setApproveOpen(false)} title={`Sayım #${countNo} · onay`}
        footer={<Button variant="ok" className="w-full" loading={busy} onClick={() => void approve()}>Onaylıyorum</Button>}>
        <p className="text-sm">
          {approval.approvals.length + 1 >= approval.required
            ? `Sizin onayınızla gereken ${approval.required} onay tamamlanır ve fark olan ${report.filter((l) => l.diff !== 0).length} ürünün stoğu hemen güncellenir. Sayım sırasında yapılan satışlar farka yansıtılır.`
            : `Onayınız kaydedilir; stok, diğer yöneticinin onayından sonra güncellenir (${approval.approvals.length + 1}/${approval.required}).`}
        </p>
      </Dialog>
      <Dialog open={reopenOpen} onClose={() => setReopenOpen(false)} title="Düzeltme için geri gönder"
        footer={<Button className="w-full" loading={busy} onClick={async () => { if (await call("reopen_stock_count", { p_count: countId, p_note: reopenNote || null }, { success: "Sayım düzeltme için geri gönderildi" })) setReopenOpen(false); }}>Geri gönder</Button>}>
        <div className="space-y-2 text-sm">
          <p>Sayım tekrar düzenlenebilir hale gelir; verilen onaylar silinir.</p>
          <Input value={reopenNote} onChange={(e) => setReopenNote(e.target.value)} placeholder="Not (isteğe bağlı), örn. Fuska damacanayı tekrar sayın" />
        </div>
      </Dialog>
      <Dialog open={cancelOpen} onClose={() => setCancelOpen(false)} title="Sayımı iptal et"
        footer={<Button variant="danger" className="w-full" loading={busy} onClick={async () => { if (await call("cancel_stock_count", { p_count: countId }, { success: "Sayım iptal edildi" })) setCancelOpen(false); }}>İptal et</Button>}>
        <p className="text-sm">Girilen miktarlar stoğa işlenmeden sayım kapatılır.</p>
      </Dialog>
    </div>
  );
}
