import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage, isNetworkError } from "@/lib/errors";
import { listQueue, markProblem, removeQueued } from "./queue";

let running = false;

/** Kuyruktaki satışları sırayla gönderir. Ağ hatasında durur, sunucu reddinde kaydı "sorunlu" işaretler. */
export async function flushQueue(): Promise<{ sent: number; problems: number }> {
  if (running || (typeof navigator !== "undefined" && !navigator.onLine)) return { sent: 0, problems: 0 };
  running = true;
  let sent = 0;
  let problems = 0;
  try {
    const items = (await listQueue()).filter((q) => q.status === "bekliyor");
    for (const q of items) {
      const { error } = await supabaseBrowser().rpc("complete_sale", { p_business: q.businessId, p: q.payload });
      if (!error) {
        await removeQueued(q.id);
        sent++;
      } else if (isNetworkError(error)) {
        break;
      } else {
        await markProblem(q.id, errorMessage(error));
        problems++;
      }
    }
  } finally {
    running = false;
  }
  return { sent, problems };
}
