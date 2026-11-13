// Horus Hotel — fonction serveur « staff-login » : connexion du personnel (code de l'établissement + identifiant + code).
// • Code de l'établissement : nouveau format NTXXXX (organizations.login_code), ou ancien code (organizations.staff_code), toujours accepté.
//   Le code interne staff_code reste la base de l'adresse et du mot de passe des comptes : les comptes existants ne changent pas.
// • Le mot de passe réel est dérivé avec une clé secrète serveur : impossible de tester les codes directement auprès de l'authentification.
// • Verrouillage : 5 échecs sur un compte => 15 min (1 h en cas de récidive dans les 24 h, et alerte au propriétaire) ; 30 échecs depuis une même adresse => 1 h ;
//   50 échecs sur un même établissement => connexions du personnel suspendues 1 h et alerte critique au propriétaire.
// • Action « change_pin » (utilisateur connecté) : changement du code personnel.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(URL_, SVC, { auth: { persistSession: false } });
const staffEmail = (code: string, user: string) => `${user}.${code}@staff.horushotel.app`;
let PEPPER: string | null = null;
async function staffPassword(code: string, user: string, pin: string) {
  if (!PEPPER) { const { data } = await admin.from("server_secrets").select("value").eq("name", "staff_pepper").single(); PEPPER = data!.value; }
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(PEPPER!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${code}|${user}|${pin}`)));
  return "hk1:" + btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
// Code saisi -> code interne (staff_code). Nouveau format NT-XXXX d'abord, puis ancien code.
async function internalCode(raw: string): Promise<string | null> {
  const t = String(raw || "").trim().replace(/\s+/g, "");
  const m = t.toUpperCase().match(/^NT-?([A-Z0-9]{4})$/);
  if (m) {
    const { data } = await admin.from("organizations").select("staff_code").eq("login_code", "NT" + m[1]).maybeSingle();
    if (data && data.staff_code) return data.staff_code;
  }
  const legacy = t.toLowerCase().replace(/-/g, "");
  return /^[a-z0-9]{3,20}$/.test(legacy) ? legacy : null;
}
async function attempt(key: string) { const { data } = await admin.from("staff_login_attempts").select("*").eq("key", key).maybeSingle(); return data; }
async function fail(key: string, max: number, lockMin: number, windowMin = 0) {
  const a = await attempt(key);
  // Fenêtre glissante (limite par établissement) : les échecs de plus de windowMin minutes ne comptent plus
  const stale = !!(windowMin && a && a.updated_at && Date.now() - new Date(a.updated_at).getTime() > windowMin * 60000 && !(a.locked_until && new Date(a.locked_until) > new Date()));
  const n = (a && !stale && !((!a.locked_until || new Date(a.locked_until) < new Date()) && a.failures >= max) ? a.failures : 0) + 1;
  // Récidive : déjà bloqué dans les dernières 24 h => blocage d'une heure
  const repeat = !!(a && a.locked_until && Date.now() - new Date(a.locked_until).getTime() < 864e5);
  const mins = n >= max ? (repeat ? Math.max(lockMin, 60) : lockMin) : 0;
  await admin.from("staff_login_attempts").upsert({ key, failures: n, locked_until: mins ? new Date(Date.now() + mins * 60000).toISOString() : (a && a.locked_until && repeat ? a.locked_until : null), updated_at: new Date().toISOString() });
  return { n, mins };
}
// Alerte au propriétaire de l'hôtel quand un compte d'employé est bloqué
async function alertOwner(code: string, user: string, mins: number) {
  try {
    const { data: org } = await admin.from("organizations").select("id").eq("staff_code", code).maybeSingle();
    if (!org) return;
    await admin.rpc("raise_owner_alert", { p_org: org.id, p_est: null, p_sev: mins >= 60 ? "critical" : "warning", p_kind: "staff_login_locked",
      p_msg: `Compte « ${user} » bloqué ${mins >= 60 ? "1 heure" : mins + " minutes"} après 5 codes erronés${mins >= 60 ? " (récidive)" : ""}.`, p_entity: "equipe", p_id: null });
  } catch (_) { /* l'alerte ne doit jamais empêcher la réponse */ }
}
// Limite globale par établissement : 50 échecs (tous comptes confondus) => connexions du personnel suspendues 1 h, alerte critique
async function alertOrg(code: string) {
  try {
    const { data: org } = await admin.from("organizations").select("id").eq("staff_code", code).maybeSingle();
    if (!org) return;
    await admin.rpc("raise_owner_alert", { p_org: org.id, p_est: null, p_sev: "critical", p_kind: "staff_login_org_locked",
      p_msg: "Nombreux codes erronés sur les comptes du personnel : connexions du personnel suspendues 1 heure par sécurité. Si ce n’est pas votre équipe, changez le code d’établissement (Équipe › Nouveau code).", p_entity: "equipe", p_id: null });
  } catch (_) { }
}
const locked = (a: any) => a && a.locked_until && new Date(a.locked_until) > new Date();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  let b: Record<string, string>; try { b = await req.json(); } catch { return json({ error: "Requête invalide." }, 400); }

  if (b.action === "change_pin") {
    const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
    const { data: { user } } = await uc.auth.getUser();
    const md = (user && user.user_metadata) || {};
    if (!user || !md.staff) return json({ error: "Connexion requise." }, 401);
    if (!/^\d{4}$/.test(b.pin || "") || /^(\d)\1{3}$/.test(b.pin) || ["1234", "4321", "0123", "9876"].includes(b.pin)) return json({ error: "Code trop simple : évitez 1111 ou 1234." }, 400);
    const { error } = await admin.auth.admin.updateUserById(user.id, { password: await staffPassword(md.staff_code, md.username, b.pin) });
    if (error) return json({ error: error.message }, 400);
    await admin.from("organization_members").update({ must_change_password: false }).eq("user_id", user.id);
    return json({ ok: true });
  }

  const user = String(b.username || "").trim().toLowerCase(), pin = String(b.pin || "");
  const code = await internalCode(String(b.code || ""));
  if (!code || !/^[a-z0-9]{2,20}$/.test(user) || !/^\d{4}$/.test(pin)) return json({ error: "Code de l’établissement, identifiant ou code incorrect." }, 400);
  // Adresse du client : en-tête posé par le réseau Cloudflare de Supabase, sinon la dernière valeur ajoutée par la passerelle
  // (la première valeur de X-Forwarded-For peut être fournie par l'attaquant).
  const xff = (req.headers.get("x-forwarded-for") || "").split(",").map((x) => x.trim()).filter(Boolean);
  const ip = (req.headers.get("cf-connecting-ip") || "").trim() || xff[xff.length - 1] || "inconnue";
  const kAcc = `acc:${code}:${user}`, kIp = `ip:${ip}`, kOrg = `org:${code}`;
  const [aAcc, aIp, aOrg] = await Promise.all([attempt(kAcc), attempt(kIp), attempt(kOrg)]);
  if (locked(aAcc)) { const m = Math.max(1, Math.ceil((new Date(aAcc.locked_until).getTime() - Date.now()) / 60000)); return json({ error: `Trop d’essais : ce compte est bloqué encore ${m} minute${m > 1 ? "s" : ""}. Votre responsable peut le débloquer ou vous donner un nouveau code.`, locked: true }, 429); }
  if (locked(aIp)) return json({ error: "Trop d’essais depuis cet appareil. Réessayez dans une heure.", locked: true }, 429);
  if (locked(aOrg)) return json({ error: "Trop d’essais sur cet établissement : connexions du personnel suspendues une heure. Le propriétaire a été prévenu et peut toujours se connecter par e-mail.", locked: true }, 429);
  const uc = createClient(URL_, ANON, { auth: { persistSession: false } });
  const { data, error } = await uc.auth.signInWithPassword({ email: staffEmail(code, user), password: await staffPassword(code, user, pin) });
  if (error || !data.session) {
    if (/banned/i.test(error?.message || "")) return json({ error: "Ce compte est suspendu. Contactez votre responsable." }, 403);
    const { n, mins } = await fail(kAcc, 5, 15); await fail(kIp, 30, 60);
    const o = await fail(kOrg, 50, 60, 60);
    if (mins) await alertOwner(code, user, mins);
    if (o.mins) await alertOrg(code);
    const left = Math.max(0, 5 - n);
    return json({ error: left ? `Code de l’établissement, identifiant ou code incorrect. ${left} essai${left > 1 ? "s" : ""} restant${left > 1 ? "s" : ""}.` : `Trop d’essais : ce compte est bloqué ${mins >= 60 ? "1 heure" : mins + " minutes"}.` }, 401);
  }
  await admin.from("staff_login_attempts").delete().eq("key", kAcc);
  return json({ ok: true, access_token: data.session.access_token, refresh_token: data.session.refresh_token });
});
