import "server-only";
import { createClient } from "@supabase/supabase-js";

/**
 * Service-role client that bypasses RLS. Only for trusted server jobs
 * (cron: delivery reminders, anomaly detection, writing notifications). Never use it
 * for a request made on behalf of a user.
 */
export function createAdminClient() {
  return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.SUPABASE_SECRET_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
