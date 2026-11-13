// Nuittea — fonction serveur « geniuspay » : paiement en ligne par l'agrégateur Genius Pay.
// • action « subscription » (utilisateur connecté, propriétaire ou administrateur) : crée le paiement chez Genius Pay
//   pour un paiement d'abonnement déjà préparé par start_subscription_checkout, et renvoie le lien de paiement.
// • action « verify » : redemande le statut à Genius Pay et valide le paiement s'il est réglé (utile au retour du client).
// • appel de Genius Pay (webhook, en-tête X-Webhook-Signature) : signature vérifiée, statut redemandé, puis validation.
// Les montants viennent toujours de la base, jamais du navigateur. Les clés restent dans les secrets du serveur.
// v10 : acompte au pourcentage réglé par l'établissement ; adresses de retour limitées aux domaines Nuittea ;
//       erreurs de Genius Pay consignées dans les journaux et non renvoyées au client.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Noms acceptés pour les secrets (ceux saisis dans le tableau de bord Supabase compris)
const env = (...names: string[]) => { for (const n of names) { const v = (Deno.env.get(n) || "").trim(); if (v) return v; } return ""; };
const GP_KEY = env("GENIUSPAY_API_KEY", "GENIUS PAY API KEY", "GENIUS_PAY_API_KEY", "apigenius");
const GP_SECRET = env("GENIUSPAY_API_SECRET", "CLE API GENIUS SECRETE", "GENIUS_PAY_API_SECRET");
const GP_WH_ENV = env("GENIUSPAY_WEBHOOK_SECRET", "GENIUS PAY WEBHOOK SECRET", "GENIUS_PAY_WEBHOOK_SECRET");
const GP_BASE = (Deno.env.get("GENIUSPAY_BASE_URL") || "https://geniuspay.ci/api/v1/merchant").replace(/\/+$/, "");
const SANDBOX = /sandbox/.test(GP_KEY) || /sandbox/.test(GP_SECRET);
const APP_URL = Deno.env.get("APP_URL") || "https://ayekouen.github.io/horus-hotel/";
const admin = createClient(URL_, SVC, { auth: { persistSession: false } });
const SELF_URL = `${URL_}/functions/v1/geniuspay`;
// Adresses de retour autorisées après paiement
const SITE_RETURN = /^https:\/\/([a-z0-9-]+\.)?nuittea\.(pages\.dev|com)\//;
const APP_RETURN = /^https:\/\/(ayekouen\.github\.io\/horus-hotel\/|([a-z0-9-]+\.)?nuittea\.(pages\.dev|com)\/)/;
// Secret webhook : celui des secrets Supabase s'il existe, sinon celui rangé à la création du webhook (table réservée au serveur)
async function webhookSecret() {
  if (GP_WH_ENV) return GP_WH_ENV;
  const { data } = await admin.from("geniuspay_settings").select("webhook_secret").eq("key", "webhook").maybeSingle();
  return data?.webhook_secret || "";
}
// Frais Genius Pay (grille publique) : 1 % + 100 F + environ 1,5 % opérateur. Le client les paie : l'hôtel reçoit le montant prévu.
const FEE_RATE = 0.025, FEE_FIXED = 100, MIN_ONLINE = 2000;
const grossUp = (net: number) => Math.ceil((net + FEE_FIXED) / (1 - FEE_RATE) / 10) * 10;

// Erreur destinée au client : message clair, sans détail technique de Genius Pay
class PublicError extends Error {}
async function gp(path: string, init: RequestInit = {}) {
  const r = await fetch(GP_BASE + path, { ...init, headers: { "X-API-Key": GP_KEY, "X-API-Secret": GP_SECRET, "Content-Type": "application/json", "Accept": "application/json", ...(init.headers || {}) } });
  const t = await r.text(); let b: any = null; try { b = JSON.parse(t); } catch { b = { raw: t.slice(0, 300) }; }
  if (!r.ok) {
    console.error("Genius Pay", init.method || "GET", path.replace(/\/payments\/[^/]+/, "/payments/…"), r.status, (b && (b.message || b.error?.message || b.error)) || t.slice(0, 200));
    throw new PublicError("Le service de paiement ne répond pas pour le moment. Réessayez dans quelques minutes.");
  }
  return b && b.data ? b.data : b;
}
const DONE = ["completed", "success", "succeeded", "paid"], FAILED = ["failed", "cancelled", "canceled", "expired"];

// Valide (ou marque en échec) un paiement d'abonnement d'après le statut renvoyé par Genius Pay
async function settleSubscription(paymentId: string, gpPay: any) {
  const st = String(gpPay.status || "").toLowerCase();
  if (DONE.includes(st)) {
    const { data, error } = await admin.rpc("confirm_subscription_payment", { p_payment_id: paymentId, p_transaction_reference: gpPay.reference || null, p_payload: { provider: "geniuspay", environment: gpPay.environment || (SANDBOX ? "sandbox" : "live"), method: gpPay.payment_method || null, fees: gpPay.fees ?? null } });
    if (error) throw new Error(error.message);
    return { status: "succeeded", result: data };
  }
  if (FAILED.includes(st)) {
    await admin.rpc("fail_subscription_payment", { p_payment_id: paymentId, p_reason: `Genius Pay : ${st}` });
    return { status: "failed" };
  }
  return { status: "pending" };
}

// Réservations Nuittea.com : validation d'après le statut renvoyé par Genius Pay
async function settleBooking(id: string, gpPay: any) {
  const st = String(gpPay.status || "").toLowerCase();
  if (gpPay.fees != null || gpPay.net_amount != null) await admin.from("booking_payments").update({ gp_fees: gpPay.fees ?? null, gp_net: gpPay.net_amount ?? null }).eq("id", id);
  if (DONE.includes(st)) {
    const { error } = await admin.rpc("confirm_booking_payment", { p_id: id, p_reference: gpPay.reference || null, p_method: gpPay.payment_method || null, p_environment: gpPay.environment || (SANDBOX ? "sandbox" : "live") });
    if (error) throw new Error(error.message);
    return { status: "succeeded" };
  }
  if (FAILED.includes(st)) { await admin.rpc("fail_booking_payment", { p_id: id }); return { status: "failed" }; }
  return { status: "pending" };
}
const SITE_URL = Deno.env.get("SITE_URL") || "https://nuittea.pages.dev/";

// Pourcentage d'acompte réglé par l'établissement (30 % tant que la migration 90 n'est pas appliquée)
async function depositPct(establishmentId: string) {
  const { data, error } = await admin.from("establishments").select("online_deposit_pct").eq("id", establishmentId).maybeSingle();
  const pct = Number((data as any)?.online_deposit_pct);
  return !error && pct >= 10 && pct <= 100 ? pct : 30;
}

async function hmacHex(secret: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg)));
  return Array.from(s).map((x) => x.toString(16).padStart(2, "0")).join("");
}
function safeEq(a: string, b: string) { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; }

Deno.serve(async (req) => {
  try { return await handle(req); } catch (e) {
    if (e instanceof PublicError) return json({ error: e.message }, 502);
    console.error("geniuspay", (e as Error).message);
    return json({ error: "Paiement en ligne momentanément indisponible. Réessayez dans quelques minutes." }, 502);
  }
});

async function handle(req: Request) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  if (!GP_KEY || !GP_SECRET) return json({ error: "Le paiement en ligne n'est pas encore configuré." }, 503);
  const raw = await req.text();

  // ---- Appel de Genius Pay (webhook) ----
  const sig = req.headers.get("x-webhook-signature");
  if (sig) {
    const GP_WH = await webhookSecret();
    if (!GP_WH) return json({ error: "Secret webhook absent." }, 503);
    const ts = req.headers.get("x-webhook-timestamp") || "";
    if (!/^\d+$/.test(ts) || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return json({ error: "Horodatage invalide." }, 401);
    const expected = await hmacHex(GP_WH, `${ts}.${raw}`);
    const given = sig.replace(/^sha256=/, "").trim().toLowerCase();
    if (!safeEq(expected, given)) return json({ error: "Signature invalide." }, 401);
    let evt: any; try { evt = JSON.parse(raw); } catch { return json({ error: "Contenu invalide." }, 400); }
    if (evt?.event === "webhook.test") return json({ ok: true, test: true });
    const ref = evt?.data?.reference;
    if (!ref) return json({ ok: true, ignored: true });
    // Double vérification : le statut fait foi seulement s'il est redemandé à Genius Pay
    const pay = await gp(`/payments/${encodeURIComponent(ref)}`);
    const md = pay.metadata || {};
    if (md.kind === "subscription" && md.payment_id) {
      const r = await settleSubscription(md.payment_id, pay);
      return json({ ok: true, ...r });
    }
    if (md.kind === "booking" && md.booking_payment_id) return json({ ok: true, ...(await settleBooking(md.booking_payment_id, pay)) });
    return json({ ok: true, ignored: true });
  }

  let b: Record<string, string>; try { b = JSON.parse(raw || "{}"); } catch { return json({ error: "Requête invalide." }, 400); }

  // ---- Nuittea.com : paiement d'une réservation qui vient d'être faite (sans compte requis) ----
  if (b.action === "booking") {
    if (SANDBOX) return json({ error: "Le paiement en ligne n'est pas encore disponible. Vous réglerez à l'hôtel." }, 403);
    const digits = (x: string) => String(x || "").replace(/[^0-9]/g, "").slice(-8);
    const { data: r } = await admin.from("reservations").select("id, organization_id, establishment_id, status, source, guest_name, guest_phone, total_amount, check_in, check_out, created_at, establishments(name, public_name)").eq("public_reference", String(b.reference || "")).maybeSingle();
    if (!r || r.source !== "naya" || digits(r.guest_phone) !== digits(b.phone) || !digits(b.phone) || Date.now() - new Date(r.created_at).getTime() > 2 * 3600e3) return json({ error: "Réservation introuvable." }, 404);
    if (!["pending", "confirmed"].includes(r.status)) return json({ error: "Cette réservation ne peut plus être payée en ligne." }, 409);
    const { data: bal } = await admin.from("reservation_balances").select("balance").eq("id", r.id).maybeSingle();
    const balance = Math.max(0, Math.round(Number(bal?.balance ?? r.total_amount)));
    const kind = b.kind === "deposit" ? "deposit" : "full";
    const pct = kind === "deposit" ? await depositPct(r.establishment_id) : 100;
    const amount = kind === "deposit" ? Math.min(balance, Math.max(200, Math.ceil(Number(r.total_amount) * pct / 100 / 100) * 100)) : balance;
    if (amount < 200) return json({ error: "Rien à payer en ligne pour cette réservation." }, 409);
    if (amount < MIN_ONLINE) return json({ error: `Le paiement en ligne commence à ${MIN_ONLINE} F. Vous réglerez à l'hôtel.` }, 409);
    const charged = grossUp(amount);
    const { data: bp, error: be } = await admin.from("booking_payments").insert({ reservation_id: r.id, organization_id: r.organization_id, establishment_id: r.establishment_id, kind, amount, charged, client_fee: charged - amount }).select("id").single();
    if (be || !bp) return json({ error: "Paiement impossible pour le moment." }, 500);
    const back = (b.return_url && SITE_RETURN.test(b.return_url) ? b.return_url : SITE_URL).split("#")[0];
    const sep = back.includes("?") ? "&" : "?";
    const hotel = (r as any).establishments?.public_name || (r as any).establishments?.name || "Hôtel";
    const created = await gp("/payments", { method: "POST", body: JSON.stringify({
      amount: charged, currency: "XOF",
      description: `${kind === "deposit" ? `Acompte ${pct} %` : "Réservation"} ${hotel} · du ${r.check_in} au ${r.check_out} · réf. ${b.reference}`.slice(0, 480),
      customer: { name: r.guest_name || "Client", phone: r.guest_phone || undefined, country: "CI" },
      success_url: `${back}${sep}gpb=${bp.id}&gps=ok`, error_url: `${back}${sep}gpb=${bp.id}&gps=ko`,
      metadata: { kind: "booking", booking_payment_id: bp.id, reservation_reference: b.reference },
    }) });
    const url = created.checkout_url || created.payment_url;
    if (!url || !created.reference) return json({ error: "Le service de paiement n'a pas renvoyé de lien. Réessayez dans quelques minutes." }, 502);
    await admin.from("booking_payments").update({ reference: created.reference, environment: created.environment || "live" }).eq("id", bp.id);
    return json({ ok: true, url, amount, fee: charged - amount, charged, pct });
  }
  if (b.action === "booking_verify") {
    const { data: bp } = await admin.from("booking_payments").select("id, status, reference, amount, kind, gp_fees").eq("id", String(b.id || "")).maybeSingle();
    if (!bp) return json({ error: "Paiement introuvable." }, 404);
    if (bp.status === "succeeded" && bp.gp_fees == null && bp.reference) { try { const g = await gp(`/payments/${encodeURIComponent(bp.reference)}`); await admin.from("booking_payments").update({ gp_fees: g.fees ?? null, gp_net: g.net_amount ?? null }).eq("id", bp.id); } catch { /* frais relevés plus tard */ } }
    if (bp.status !== "pending" || !bp.reference) return json({ status: bp.status, amount: bp.amount, kind: bp.kind });
    const gpPay = await gp(`/payments/${encodeURIComponent(bp.reference)}`);
    return json({ ...(await settleBooking(bp.id, gpPay)), amount: bp.amount, kind: bp.kind });
  }

  // ---- Appels de l'application (utilisateur connecté) ----
  const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false } });
  const { data: { user } } = await uc.auth.getUser();
  if (!user) return json({ error: "Connexion requise." }, 401);

  if (b.action === "webhook_status" || b.action === "webhook_setup") {
    const { data: isAdm } = await uc.rpc("is_platform_admin");
    if (!isAdm) return json({ error: "Accès refusé." }, 403);
    const { data: cur } = await admin.from("geniuspay_settings").select("webhook_id, webhook_url, environment, created_at, webhook_secret").eq("key", "webhook").maybeSingle();
    const st = (c: any) => ({ active: !!(c && c.webhook_secret) || !!GP_WH_ENV, webhook_id: c?.webhook_id || null, url: c?.webhook_url || SELF_URL, environment: c?.environment || null, created_at: c?.created_at || null });
    if (b.action === "webhook_status" || (cur && cur.webhook_secret)) {
      if (b.action === "webhook_setup" && cur?.webhook_id) { try { await gp(`/webhooks/${cur.webhook_id}/test`, { method: "POST" }); } catch { /* test facultatif */ } }
      return json(st(cur));
    }
    const w = await gp("/webhooks", { method: "POST", body: JSON.stringify({ name: "Nuittea", url: SELF_URL, events: ["payment.success", "payment.failed", "payment.cancelled", "payment.expired", "payment.refunded"] }) });
    const secret = w.secret || w.webhook_secret || w.signing_secret;
    if (!secret) return json({ error: "Genius Pay n'a pas renvoyé de secret pour le webhook." }, 502);
    const row = { key: "webhook", webhook_id: String(w.id ?? ""), webhook_secret: secret, webhook_url: SELF_URL, environment: w.environment || (SANDBOX ? "sandbox" : "live") };
    const { error: se } = await admin.from("geniuspay_settings").upsert(row);
    if (se) { console.error("geniuspay_settings", se.message); return json({ error: "Webhook créé mais secret non enregistré. Consultez les journaux du serveur." }, 500); }
    try { if (row.webhook_id) await gp(`/webhooks/${row.webhook_id}/test`, { method: "POST" }); } catch { /* test facultatif */ }
    return json(st(row));
  }

  if (b.action === "subscription" || b.action === "verify") {
    const { data: pay } = await admin.from("payments").select("id, organization_id, amount, currency, status, payment_method, transaction_reference, metadata, plans(name)").eq("id", b.payment_id).maybeSingle();
    if (!pay) return json({ error: "Paiement introuvable." }, 404);
    const { data: m } = await admin.from("organization_members").select("role").eq("organization_id", pay.organization_id).eq("user_id", user.id).eq("is_active", true).maybeSingle();
    const { data: isAdm } = await uc.rpc("is_platform_admin");
    if (!isAdm && !(m && ["owner", "admin"].includes(m.role))) return json({ error: "Accès refusé." }, 403);
    // En mode test (clés sandbox), seul l'administrateur de la plateforme peut payer : aucun hôtel n'est prolongé avec de l'argent fictif.
    if (SANDBOX && !isAdm) return json({ error: "Le paiement en ligne est en cours de mise en service. Utilisez un autre moyen de paiement pour le moment." }, 403);

    if (b.action === "verify") {
      if (pay.status !== "pending") return json({ status: pay.status });
      if (!pay.transaction_reference) return json({ status: "pending" });
      const gpPay = await gp(`/payments/${encodeURIComponent(pay.transaction_reference)}`);
      return json(await settleSubscription(pay.id, gpPay));
    }

    if (pay.status !== "pending" || pay.payment_method !== "geniuspay") return json({ error: "Ce paiement ne peut plus être réglé en ligne." }, 409);
    const { data: org } = await admin.from("organizations").select("name").eq("id", pay.organization_id).maybeSingle();
    const back = (b.return_url && APP_RETURN.test(b.return_url) ? b.return_url : APP_URL).split("#")[0];
    const sep = back.includes("?") ? "&" : "?";
    const created = await gp("/payments", { method: "POST", body: JSON.stringify({
      amount: pay.amount, currency: pay.currency || "XOF",
      description: `Abonnement Nuittea Manager · ${(pay as any).plans?.name || "formule"} · ${org?.name || ""}`.slice(0, 480),
      customer: { name: org?.name || "Client Nuittea", email: user.email || undefined, country: "CI" },
      success_url: `${back}${sep}gp=${pay.id}&gps=ok`, error_url: `${back}${sep}gp=${pay.id}&gps=ko`,
      metadata: { kind: "subscription", payment_id: pay.id, organization_id: pay.organization_id },
    }) });
    const url = created.checkout_url || created.payment_url;
    if (!url || !created.reference) return json({ error: "Le service de paiement n'a pas renvoyé de lien. Réessayez dans quelques minutes." }, 502);
    await admin.from("payments").update({ transaction_reference: created.reference, metadata: { ...(pay.metadata || {}), geniuspay: { reference: created.reference, environment: created.environment || (SANDBOX ? "sandbox" : "live") } } }).eq("id", pay.id);
    return json({ ok: true, url, reference: created.reference, sandbox: SANDBOX });
  }

  return json({ error: "Action inconnue." }, 400);
}
