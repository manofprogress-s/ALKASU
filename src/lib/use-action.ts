"use client";
import { useCallback, useState } from "react";
import { useRouter } from "next/navigation";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";

/** Yetki kontrollü bir RPC'yi çağırır; hata mesajını gösterir, başarıda sayfayı yeniler. */
export function useRpc() {
  const router = useRouter();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const call = useCallback(
    async <T = unknown>(fn: string, args: Record<string, unknown>, opts?: { success?: string; refresh?: boolean }): Promise<T | null> => {
      setBusy(true);
      const { data, error } = await supabaseBrowser().rpc(fn, args);
      setBusy(false);
      if (error) {
        toast(errorMessage(error), "danger");
        return null;
      }
      if (opts?.success) toast(opts.success, "ok");
      if (opts?.refresh !== false) router.refresh();
      return (data ?? true) as T;
    },
    [router, toast],
  );
  return { call, busy };
}
