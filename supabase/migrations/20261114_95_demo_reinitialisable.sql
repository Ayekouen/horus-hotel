-- 95 · La démonstration « Hôtel Démo Nuittea » redevient réinitialisable (appliquée le 14/11/2026).
-- Les écritures de caisse et les factures restent définitives pour tous les vrais établissements.
create or replace function public.forbid_change() returns trigger language plpgsql set search_path to '' as $$
begin
  if tg_op = 'DELETE' and current_user in ('postgres', 'supabase_admin')
     and exists (select 1 from public.organizations o where o.id = old.organization_id and o.is_test and o.name = 'Hôtel Démo Nuittea') then
    return old;
  end if;
  raise exception 'Opération interdite : les écritures de caisse et les factures sont définitives.';
end $$;
-- 95b (demo_seed_complet) : demo_seed efface aussi guest_invoices et room_passes de la démonstration avant les réservations.
