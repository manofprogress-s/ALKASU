"use client";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card, Empty, PageHeader } from "@/components/ui/card";
import { useToast } from "@/components/ui/toast";
import { formatDateTime, formatTRY } from "@/lib/format";
import { listQueue, markRetry, onQueueChange, removeQueued, type QueuedSale } from "@/lib/offline/queue";
import { flushQueue } from "@/lib/offline/sync";

export default function PendingSales() {
  const toast = useToast();
  const [items, setItems] = useState<QueuedSale[]>([]);
  const [now, setNow] = useState(0);
  useEffect(() => {
    const load = async () => {
      setItems(await listQueue());
      setNow(Date.now());
    };
    void load();
    return onQueueChange(() => void load());
  }, []);

  async function sendNow() {
    const r = await flushQueue();
    toast(r.sent ? `${r.sent} satış gönderildi` : "Gönderilecek satış yok veya bağlantı yok", r.sent ? "ok" : "info");
  }

  const stale = items.filter((i) => now > 0 && now - new Date(i.createdAt).getTime() > 72 * 3600_000);

  return (
    <div className="space-y-4">
      <PageHeader title="Gönderilmemiş satışlar" subtitle="Bu cihazda bekleyen çevrimdışı satışlar" actions={<Button onClick={sendNow}>Şimdi gönder</Button>} />
      {stale.length > 0 ? <Alert tone="warn">{stale.length} satış 72 saatten eski (C-04). Gönderimden önce kontrol edin.</Alert> : null}
      {items.length === 0 ? <Empty>Bekleyen satış yok.</Empty> : null}
      {items.map((q) => (
        <Card key={q.id} className="space-y-2">
          <div className="flex items-center justify-between">
            <div>
              <div className="font-medium">{formatDateTime(q.createdAt)}</div>
              <div className="num text-sm text-muted">{formatTRY(q.total)}</div>
            </div>
            {q.status === "sorunlu" ? <Badge tone="danger">Sorunlu</Badge> : <Badge tone="brand">Bekliyor</Badge>}
          </div>
          {q.lastError ? <Alert>{q.lastError}</Alert> : null}
          {q.status === "sorunlu" ? (
            <div className="flex gap-2">
              <Button size="sm" variant="secondary" onClick={() => markRetry(q.id)}>Tekrar dene</Button>
              <Button size="sm" variant="danger" onClick={() => {
                if (confirm("Bu satış kalıcı olarak silinecek ve sunucuya hiç gönderilmeyecek. Emin misiniz?")) void removeQueued(q.id);
              }}>Sil</Button>
            </div>
          ) : null}
        </Card>
      ))}
    </div>
  );
}
