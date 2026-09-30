"use client";
import { CheckCircle2, CloudOff, Printer } from "lucide-react";
import { Dialog } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { useAppContext } from "@/components/shell/context";
import { formatDateTime, formatTRY } from "@/lib/format";
import type { SaleResult } from "./payment-dialog";

const METHOD: Record<string, string> = { nakit: "Nakit", pos: "POS", veresiye: "Veresiye" };

export function ReceiptDialog({ result, onClose }: { result: SaleResult | null; onClose: () => void }) {
  const ctx = useAppContext();
  if (!result) return null;
  return (
    <Dialog
      open
      onClose={onClose}
      title={result.offline ? "Satış kuyruğa alındı" : "Satış tamamlandı"}
      footer={
        <div className="flex gap-2">
          <Button variant="secondary" onClick={() => window.print()}>
            <Printer className="h-4 w-4" /> Yazdır
          </Button>
          <Button size="lg" className="flex-1" onClick={onClose} autoFocus>
            Yeni satış
          </Button>
        </div>
      }
    >
      <div className="mb-4 flex flex-col items-center gap-1 text-center">
        {result.offline ? <CloudOff className="h-10 w-10 text-warn" /> : <CheckCircle2 className="h-10 w-10 text-ok" />}
        {result.offline ? (
          <p className="text-sm text-muted">İnternet yok. Satış bu cihazda saklandı ve bağlantı gelince otomatik gönderilecek.</p>
        ) : null}
        {result.change !== null && result.change > 0 ? (
          <div className="num mt-2 rounded-xl bg-ok-soft px-4 py-2 text-xl font-bold text-ok">Para üstü {formatTRY(result.change)}</div>
        ) : null}
      </div>

      <div id="receipt" className="mx-auto max-w-xs rounded-xl border border-dashed border-border p-3 font-mono text-[13px] leading-5">
        <div className="text-center font-bold">{ctx.businessName}</div>
        <div className="text-center text-xs">BİLGİ FİŞİ — mali değeri yoktur</div>
        <div className="mt-1 flex justify-between text-xs">
          <span>{result.no ? `No: ${result.no}` : "No: (gönderilecek)"}</span>
          <span>{formatDateTime(result.at)}</span>
        </div>
        {result.customerName ? <div className="text-xs">Müşteri: {result.customerName}</div> : null}
        <hr className="my-2 border-dashed border-border" />
        {result.lines.map((l, i) => (
          <div key={i} className="flex justify-between gap-2">
            <span className="min-w-0 truncate">
              {l.qty} {l.unit} {l.name}
            </span>
            <span>{formatTRY(l.total)}</span>
          </div>
        ))}
        {result.discount > 0 ? (
          <div className="flex justify-between text-xs">
            <span>İndirim</span>
            <span>−{formatTRY(result.discount)}</span>
          </div>
        ) : null}
        {result.deposit !== 0 ? (
          <div className="flex justify-between">
            <span>Depozito</span>
            <span>{formatTRY(result.deposit)}</span>
          </div>
        ) : null}
        <hr className="my-2 border-dashed border-border" />
        <div className="flex justify-between font-bold">
          <span>TOPLAM</span>
          <span>{formatTRY(result.total)}</span>
        </div>
        {result.payments.map((p) => (
          <div key={p.method} className="flex justify-between text-xs">
            <span>{METHOD[p.method]}</span>
            <span>{formatTRY(p.amount)}</span>
          </div>
        ))}
      </div>
    </Dialog>
  );
}
