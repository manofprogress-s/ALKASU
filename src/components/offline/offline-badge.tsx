"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { CloudOff, RefreshCw } from "lucide-react";
import { listQueue, onQueueChange } from "@/lib/offline/queue";

export function OfflineBadge() {
  const [online, setOnline] = useState(() => (typeof navigator === "undefined" ? true : navigator.onLine));
  const [pending, setPending] = useState(0);
  const [problems, setProblems] = useState(0);
  useEffect(() => {
    const update = async () => {
      const q = await listQueue();
      setPending(q.filter((x) => x.status === "bekliyor").length);
      setProblems(q.filter((x) => x.status === "sorunlu").length);
    };
    void update();
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    const unsub = onQueueChange(() => void update());
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
      unsub();
    };
  }, []);

  if (online && pending === 0 && problems === 0) return null;
  return (
    <Link href="/satislar/bekleyen" className="flex items-center gap-2">
      {!online ? (
        <span className="inline-flex items-center gap-1 rounded-full bg-warn-soft px-2 py-1 text-xs font-medium text-warn">
          <CloudOff className="h-3.5 w-3.5" /> Çevrimdışı
        </span>
      ) : null}
      {pending > 0 ? (
        <span className="inline-flex items-center gap-1 rounded-full bg-brand-soft px-2 py-1 text-xs font-medium text-brand">
          <RefreshCw className="h-3.5 w-3.5" /> {pending} gönderilmedi
        </span>
      ) : null}
      {problems > 0 ? (
        <span className="rounded-full bg-danger-soft px-2 py-1 text-xs font-medium text-danger">{problems} sorunlu</span>
      ) : null}
    </Link>
  );
}
