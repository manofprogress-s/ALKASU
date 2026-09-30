"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { flushQueue } from "@/lib/offline/sync";
import { useToast } from "@/components/ui/toast";

export function OfflineSync() {
  const toast = useToast();
  const router = useRouter();
  useEffect(() => {
    let alive = true;
    const run = async () => {
      const r = await flushQueue();
      if (!alive) return;
      if (r.sent > 0) {
        toast(`${r.sent} bekleyen satış gönderildi`, "ok");
        router.refresh();
      }
      if (r.problems > 0) toast(`${r.problems} satış sunucuda reddedildi. Satışlar → Bekleyenler'e bakın.`, "danger");
    };
    void run();
    const onOnline = () => void run();
    window.addEventListener("online", onOnline);
    const t = setInterval(run, 30_000);
    return () => {
      alive = false;
      window.removeEventListener("online", onOnline);
      clearInterval(t);
    };
  }, [toast, router]);
  return null;
}
