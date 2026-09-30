"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { Alert, Card } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import { formatTRY, parseAmount, todayISO } from "@/lib/format";

const COINS = [200, 100, 50, 20, 10, 5, 1, 0.5, 0.25];

export function CashActions({ sessionId, expected, posExpected, categories }: {
  sessionId: string | null; expected: number; posExpected: number; categories: { id: string; name: string }[];
}) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [dlg, setDlg] = useState<"gider" | "hareket" | "kapat" | null>(null);
  // gider
  const [cat, setCat] = useState(categories[0]?.id ?? "");
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState("kasa");
  const [desc, setDesc] = useState("");
  const [date, setDate] = useState(todayISO());
  // hareket
  const [mvType, setMvType] = useState("cikis");
  // kapanış
  const [counted, setCounted] = useState("");
  const [coins, setCoins] = useState<Record<number, string>>({});
  const [carry, setCarry] = useState("");
  const [slip, setSlip] = useState(posExpected ? String(posExpected).replace(".", ",") : "");
  const [note, setNote] = useState("");

  const coinTotal = COINS.reduce((s, c) => s + c * (parseInt(coins[c] ?? "", 10) || 0), 0);
  const countedN = Object.values(coins).some((v) => v) ? coinTotal : parseAmount(counted);
  const diff = countedN !== null ? Math.round((countedN - expected) * 100) / 100 : null;
  const carryN = parseAmount(carry) ?? 0;
  const reset = () => { setAmount(""); setDesc(""); setDlg(null); };

  return (
    <Card className="flex flex-wrap gap-2">
      <Button variant="secondary" onClick={() => setDlg("gider")}>Gider ekle</Button>
      <Button variant="secondary" onClick={() => setDlg("hareket")}>Kasaya giriş / çıkış</Button>
      <Button variant="primary" disabled={!sessionId} onClick={() => setDlg("kapat")}>Gün sonu kapat</Button>

      <Dialog open={dlg === "gider"} onClose={() => setDlg(null)} title="Gider"
        footer={<Button className="w-full" loading={busy} disabled={!parseAmount(amount) || !cat}
          onClick={async () => { if (await call("add_expense", { p_business: ctx.businessId, p: { id: crypto.randomUUID(), category_id: cat, amount: parseAmount(amount), method, description: desc, expense_date: date } }, { success: "Gider kaydedildi" })) reset(); }}>
          Kaydet</Button>}>
        <div className="space-y-3">
          <Field label="Kategori"><Select value={cat} onChange={(e) => setCat(e.target.value)}>{categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          <Field label="Tutar ₺"><Input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
          <Field label="Ödeme"><Select value={method} onChange={(e) => setMethod(e.target.value)}><option value="kasa">Kasadan nakit</option><option value="banka">Banka / kart (kasayı etkilemez)</option></Select></Field>
          <Field label="Tarih"><Input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="Açıklama"><Input value={desc} onChange={(e) => setDesc(e.target.value)} /></Field>
        </div>
      </Dialog>

      <Dialog open={dlg === "hareket"} onClose={() => setDlg(null)} title="Kasa hareketi"
        footer={<Button className="w-full" loading={busy} disabled={!parseAmount(amount) || !desc.trim()}
          onClick={async () => { if (await call("add_cash_movement", { p_business: ctx.businessId, p: { type: mvType, amount: parseAmount(amount), note: desc } }, { success: "Kaydedildi" })) reset(); }}>
          Kaydet</Button>}>
        <div className="space-y-3">
          <Field label="Tür"><Select value={mvType} onChange={(e) => setMvType(e.target.value)}><option value="cikis">Kasadan çıkış (bankaya yatırma, sahibe teslim)</option><option value="giris">Kasaya giriş (bozuk para vb.)</option></Select></Field>
          <Field label="Tutar ₺"><Input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
          <Field label="Açıklama"><Input value={desc} onChange={(e) => setDesc(e.target.value)} /></Field>
        </div>
      </Dialog>

      <Dialog open={dlg === "kapat"} onClose={() => setDlg(null)} title="Gün sonu kapatma" wide
        footer={<Button className="w-full" variant="ok" loading={busy} disabled={countedN === null || carryN > (countedN ?? 0)}
          onClick={async () => {
            if (!confirm("Kasa günü kapatılacak. Kapanan gün değiştirilemez. Devam edilsin mi?")) return;
            if (await call("close_cash_session", { p_business: ctx.businessId, p: { session_id: sessionId, counted_cash: countedN, carry_over: carryN, pos_slip: parseAmount(slip), diff_note: note } }, { success: "Kasa kapatıldı" })) setDlg(null);
          }}>Kasayı kapat</Button>}>
        <div className="space-y-4">
          <div className="num rounded-xl bg-surface-2 p-3 text-center">
            <div className="text-sm text-muted">Kasada olması gereken nakit</div>
            <div className="text-2xl font-bold">{formatTRY(expected)}</div>
          </div>
          <Field label="Sayılan nakit ₺" hint="Veya aşağıdaki küpür sayacını kullanın">
            <Input inputMode="decimal" value={Object.values(coins).some((v) => v) ? String(coinTotal) : counted} onChange={(e) => { setCoins({}); setCounted(e.target.value); }} />
          </Field>
          <details>
            <summary className="cursor-pointer text-sm text-brand">Küpür sayacı</summary>
            <div className="mt-2 grid grid-cols-3 gap-2">
              {COINS.map((c) => (
                <label key={c} className="flex items-center gap-2 text-sm">
                  <span className="num w-14 text-right">{c >= 1 ? `${c} ₺` : `${c * 100} kr`}</span>
                  <Input className="h-9" inputMode="numeric" value={coins[c] ?? ""} onChange={(e) => setCoins((x) => ({ ...x, [c]: e.target.value.replace(/\D/g, "") }))} />
                </label>
              ))}
            </div>
          </details>
          {diff !== null ? (
            <Alert tone={diff === 0 ? "ok" : "warn"}>Fark: {formatTRY(diff)} {diff > 0 ? "(fazla)" : diff < 0 ? "(eksik)" : ""}</Alert>
          ) : null}
          {diff !== null && diff !== 0 ? <Field label="Fark açıklaması" hint="Tolerans aşılırsa zorunludur"><Input value={note} onChange={(e) => setNote(e.target.value)} /></Field> : null}
          <Field label={`POS slip toplamı ₺ (sistem: ${formatTRY(posExpected)})`}><Input inputMode="decimal" value={slip} onChange={(e) => setSlip(e.target.value)} /></Field>
          <Field label="Yarına devreden nakit ₺" hint={countedN !== null ? `Kalan ${formatTRY(Math.max((countedN ?? 0) - carryN, 0))} gün sonu teslim olarak kaydedilir` : undefined}>
            <Input inputMode="decimal" value={carry} onChange={(e) => setCarry(e.target.value)} placeholder="0" />
          </Field>
        </div>
      </Dialog>
    </Card>
  );
}
