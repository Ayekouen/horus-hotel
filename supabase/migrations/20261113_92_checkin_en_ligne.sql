-- 92 · Check-in en ligne : le client remplit sa fiche depuis un lien avant son arrivée.
-- Données personnelles limitées au nécessaire, visibles par l'hôtel seulement, effacées 30 jours après le départ. Ajouts uniquement.

create table if not exists public.checkin_forms (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  reservation_id uuid not null unique references public.reservations(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  status text not null default 'sent' check (status in ('sent', 'submitted', 'applied')),
  data jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  purge_after date
);
alter table public.checkin_forms enable row level security;
revoke all on table public.checkin_forms from anon;
grant select on table public.checkin_forms to authenticated;
drop policy if exists cf_select on public.checkin_forms;
create policy cf_select on public.checkin_forms for select to authenticated
  using ((select public.has_org_role(checkin_forms.organization_id, array['owner', 'admin', 'manager', 'receptionist'])));

-- Création du lien par la réception
create or replace function public.request_online_checkin(p_reservation uuid) returns uuid
language plpgsql security definer set search_path to '' as $$
declare r public.reservations; v uuid;
begin
  select * into r from public.reservations where id = p_reservation;
  if r.id is null or not public.has_org_role(r.organization_id, array['owner', 'admin', 'manager', 'receptionist']) then raise exception 'Accès refusé.'; end if;
  if r.status not in ('pending', 'confirmed') then raise exception 'Le check-in en ligne se fait avant l''arrivée.'; end if;
  insert into public.checkin_forms (organization_id, establishment_id, reservation_id, purge_after)
  values (r.organization_id, r.establishment_id, r.id, r.check_out + 30)
  on conflict (reservation_id) do update set purge_after = excluded.purge_after
  returning token into v;
  return v;
end $$;
revoke all on function public.request_online_checkin(uuid) from public, anon;
grant execute on function public.request_online_checkin(uuid) to authenticated;

-- Page publique : informations du séjour (sans données personnelles au-delà du prénom)
create or replace function public.public_checkin_get(p_token uuid) returns jsonb
language sql stable security definer set search_path to '' as $$
  select case when f.id is null then jsonb_build_object('ok', false) else jsonb_build_object('ok', true, 'status', f.status,
    'guest', split_part(coalesce(g.full_name, r.guest_name, ''), ' ', 1), 'hotel', coalesce(e.public_name, e.name), 'logo', e.public_logo_url,
    'check_in', r.check_in, 'check_out', r.check_out, 'arrival_from', left(e.checkin_time::text, 5), 'room_type', rm.room_type) end
  from (select 1) d
  left join public.checkin_forms f on f.token = p_token
  left join public.reservations r on r.id = f.reservation_id
  left join public.guests g on g.id = r.guest_id
  left join public.establishments e on e.id = f.establishment_id
  left join public.rooms rm on rm.id = r.room_id
$$;
revoke all on function public.public_checkin_get(uuid) from public;
grant execute on function public.public_checkin_get(uuid) to anon, authenticated;

-- Envoi de la fiche par le client
create or replace function public.public_checkin_submit(p_token uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare f public.checkin_forms; r public.reservations; v jsonb; t text;
begin
  if public._rate_hit('checkin:ip:' || public._client_ip(), 10, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'Trop de tentatives. Réessayez plus tard.'); end if;
  select * into f from public.checkin_forms where token = p_token;
  if f.id is null then return jsonb_build_object('ok', false, 'error', 'Lien invalide.'); end if;
  select * into r from public.reservations where id = f.reservation_id;
  if r.status not in ('pending', 'confirmed') or r.check_out < current_date then return jsonb_build_object('ok', false, 'error', 'Ce séjour n''est plus modifiable en ligne.'); end if;
  if length(trim(coalesce(p->>'full_name', ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Indiquez votre nom complet.'); end if;
  t := coalesce(p->>'id_type', '');
  if t not in ('', 'cni', 'passeport', 'permis', 'carte_consulaire', 'autre') then return jsonb_build_object('ok', false, 'error', 'Type de pièce inconnu.'); end if;
  v := jsonb_strip_nulls(jsonb_build_object(
    'full_name', left(trim(p->>'full_name'), 120),
    'phone', left(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+ ]', '', 'g'), 30),
    'email', nullif(left(trim(coalesce(p->>'email', '')), 160), ''),
    'nationality', nullif(left(trim(coalesce(p->>'nationality', '')), 60), ''),
    'id_type', nullif(t, ''),
    'id_number', nullif(left(regexp_replace(coalesce(p->>'id_number', ''), '[^A-Za-z0-9 -]', '', 'g'), 40), ''),
    'arrival_time', nullif(left(coalesce(p->>'arrival_time', ''), 5), ''),
    'guests', least(greatest(coalesce((p->>'guests')::int, 1), 1), 20),
    'requests', nullif(left(trim(coalesce(p->>'requests', '')), 500), '')));
  update public.checkin_forms set data = v, status = 'submitted', submitted_at = now() where id = f.id;
  insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message)
  values (f.organization_id, f.establishment_id, 'info', 'online_checkin', format('Check-in en ligne reçu : %s, arrivée le %s%s.', v->>'full_name', to_char(r.check_in, 'DD/MM'), coalesce(' vers ' || (v->>'arrival_time'), '')));
  perform public._push(f.organization_id, f.establishment_id, 'booking', 'Check-in en ligne', format('%s a rempli sa fiche (arrivée le %s).', v->>'full_name', to_char(r.check_in, 'DD/MM')), '?go=reservations', array['owner', 'admin', 'manager', 'receptionist']);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.public_checkin_submit(uuid, jsonb) from public;
grant execute on function public.public_checkin_submit(uuid, jsonb) to anon, authenticated;

-- La réception reporte la fiche sur le client et la réservation
create or replace function public.apply_online_checkin(p_reservation uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare f public.checkin_forms; r public.reservations;
begin
  select * into f from public.checkin_forms where reservation_id = p_reservation;
  select * into r from public.reservations where id = p_reservation;
  if f.id is null or r.id is null or not public.has_org_role(r.organization_id, array['owner', 'admin', 'manager', 'receptionist']) then raise exception 'Accès refusé.'; end if;
  if f.status <> 'submitted' then raise exception 'Aucune fiche à reporter.'; end if;
  if r.guest_id is not null then
    update public.guests set full_name = coalesce(nullif(f.data->>'full_name', ''), full_name), phone = coalesce(nullif(f.data->>'phone', ''), phone) where id = r.guest_id;
  end if;
  update public.reservations set adults = coalesce((f.data->>'guests')::int, adults),
    notes = nullif(concat_ws(' · ', notes, 'Check-in en ligne' || coalesce(' : arrivée vers ' || (f.data->>'arrival_time'), '') || coalesce(' · ' || (f.data->>'requests'), '')), '')
   where id = r.id;
  update public.checkin_forms set status = 'applied' where id = f.id;
end $$;
revoke all on function public.apply_online_checkin(uuid) from public, anon;
grant execute on function public.apply_online_checkin(uuid) to authenticated;

-- Effacement des données 30 jours après le départ
create or replace function public.purge_checkin_forms() returns int language sql security definer set search_path to '' as $$
  with d as (delete from public.checkin_forms where purge_after < current_date returning 1) select count(*)::int from d
$$;
revoke all on function public.purge_checkin_forms() from public, anon, authenticated;
select cron.schedule('purge-checkin-forms', '17 3 * * *', 'select public.purge_checkin_forms()')
 where not exists (select 1 from cron.job where jobname = 'purge-checkin-forms');
