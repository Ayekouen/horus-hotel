-- 91 · Alertes antifraude pour le propriétaire (cloche + notification).
-- Contrôles côté serveur, déclenchés automatiquement ; seuils réglables par organisation. Ajouts uniquement.

alter table public.organizations add column if not exists fraud_rules jsonb not null default
  '{"enabled": true, "discount_count": 3, "discount_days": 7, "gap_count": 3, "gap_days": 30, "room_without_booking": true}'::jsonb;

-- Une alerte par sujet et par jour au plus (évite les doublons) ; p_key est un fragment visible du message (client, employé, chambre)
create or replace function public._fraud_alert(p_org uuid, p_est uuid, p_kind text, p_key text, p_msg text, p_sev text default 'warning')
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not coalesce((select (fraud_rules->>'enabled')::boolean from public.organizations where id = p_org), true) then return; end if;
  if exists (select 1 from public.owner_alerts where organization_id = p_org and kind = p_kind and message like '%' || p_key || '%'
             and created_at > now() - interval '20 hours') then return; end if;
  insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message)
  values (p_org, p_est, p_sev, p_kind, p_msg);
  perform public._push(p_org, p_est, 'alert', 'Alerte · contrôle', p_msg, '?go=controle', array['owner', 'admin']);
end $$;
revoke all on function public._fraud_alert(uuid, uuid, text, text, text, text) from public, anon, authenticated;

create or replace function public._actor_name(p_org uuid, p_user uuid) returns text language sql stable security definer set search_path to '' as $$
  select coalesce((select coalesce(m.display_name, m.username) from public.organization_members m where m.organization_id = p_org and m.user_id = p_user limit 1), 'un membre de l''équipe')
$$;
revoke all on function public._actor_name(uuid, uuid) from public, anon, authenticated;

-- 1. Réservation annulée, ou montant baissé, alors qu'un paiement a déjà été encaissé
create or replace function public._fraud_resa() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_paid numeric; v_who text; v_n int; r jsonb;
begin
  r := (select fraud_rules from public.organizations where id = new.organization_id);
  v_who := public._actor_name(new.organization_id, auth.uid());
  if tg_op = 'UPDATE' then
    select coalesce(sum(amount) filter (where kind = 'payment'), 0) - coalesce(sum(amount) filter (where kind = 'refund'), 0)
      into v_paid from public.cash_movements where reservation_id = new.id;
    if v_paid > 0 and new.status in ('cancelled', 'no_show') and old.status not in ('cancelled', 'no_show') then
      perform public._fraud_alert(new.organization_id, new.establishment_id, 'fraud_cancel_paid', coalesce(new.guest_name, 'un client'),
        format('Réservation de %s annulée par %s alors que %s F avaient été encaissés.', coalesce(new.guest_name, 'un client'), v_who, public._fcfa(v_paid)), 'critical');
    elsif v_paid > 0 and coalesce(new.total_amount, 0) < coalesce(old.total_amount, 0) then
      perform public._fraud_alert(new.organization_id, new.establishment_id, 'fraud_amount_down', coalesce(new.guest_name, 'un client'),
        format('Montant de la réservation de %s baissé par %s après encaissement : %s F → %s F.', coalesce(new.guest_name, 'un client'), v_who, public._fcfa(old.total_amount), public._fcfa(new.total_amount)));
    end if;
  end if;
  -- 2. Remises répétées par un même employé
  if coalesce(new.discount, 0) > 0 and (tg_op = 'INSERT' or coalesce(old.discount, 0) = 0) and auth.uid() is not null then
    select count(*) into v_n from public.reservations
     where organization_id = new.organization_id and created_by = auth.uid() and coalesce(discount, 0) > 0
       and created_at > now() - make_interval(days => coalesce((r->>'discount_days')::int, 7));
    if v_n >= coalesce((r->>'discount_count')::int, 3) then
      perform public._fraud_alert(new.organization_id, new.establishment_id, 'fraud_discounts', v_who,
        format('%s a accordé %s remises en %s jours.', v_who, v_n, coalesce((r->>'discount_days')::int, 7)));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_zz_fraud_resa on public.reservations;
create trigger trg_zz_fraud_resa after insert or update on public.reservations for each row execute function public._fraud_resa();

-- 3. Chambre passée « à nettoyer » sans séjour ce jour-là ni la veille (occupation non déclarée ?)
create or replace function public._fraud_room() returns trigger language plpgsql security definer set search_path to '' as $$
declare d date := (now() at time zone 'Africa/Abidjan')::date;
begin
  if new.housekeeping_status = 'dirty' and old.housekeeping_status = 'clean'
     and coalesce((select (fraud_rules->>'room_without_booking')::boolean from public.organizations where id = new.organization_id), true)
     and not exists (select 1 from public.reservations x where x.room_id = new.id and x.status in ('checked_in', 'checked_out')
                     and x.check_in <= d and x.check_out >= d - 1)
     and not exists (select 1 from public.room_passes p where p.room_id = new.id and p.created_at > now() - interval '30 hours') then
    perform public._fraud_alert(new.organization_id, new.establishment_id, 'fraud_room_used', 'Chambre ' || new.number || ' ',
      format('Chambre %s passée « à nettoyer » par %s sans séjour enregistré aujourd''hui ni hier.', new.number, public._actor_name(new.organization_id, auth.uid())));
  end if;
  return new;
end $$;
drop trigger if exists trg_zz_fraud_room on public.rooms;
create trigger trg_zz_fraud_room after update of housekeeping_status on public.rooms for each row execute function public._fraud_room();

-- 4. Écarts de caisse répétés par la même personne
create or replace function public._fraud_cash_gap() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_n int; r jsonb; v_exp numeric;
begin
  if new.status = 'closed' and old.status = 'open' then
    r := (select fraud_rules from public.organizations where id = new.organization_id);
    select count(*) into v_n from public.cash_sessions s
     where s.organization_id = new.organization_id and s.closed_by = new.closed_by and s.status = 'closed'
       and s.closed_at > now() - make_interval(days => coalesce((r->>'gap_days')::int, 30))
       and coalesce(s.counted_balance, 0) <> s.opening_balance + coalesce((select sum(case when kind in ('payment', 'income', 'transfer_in') then amount else -amount end)
             from public.cash_movements m where m.session_id = s.id and m.method = 'cash'), 0);
    if v_n >= coalesce((r->>'gap_count')::int, 3) then
      perform public._fraud_alert(new.organization_id, new.establishment_id, 'fraud_cash_gaps', public._actor_name(new.organization_id, new.closed_by),
        format('%s a clôturé %s caisses avec un écart en %s jours.', public._actor_name(new.organization_id, new.closed_by), v_n, coalesce((r->>'gap_days')::int, 30)), 'critical');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_zz_fraud_cash_gap on public.cash_sessions;
create trigger trg_zz_fraud_cash_gap after update on public.cash_sessions for each row execute function public._fraud_cash_gap();

-- Réglage des seuils par le propriétaire uniquement
create or replace function public.set_fraud_rules(p_org uuid, p_rules jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare v jsonb;
begin
  if not public.has_org_role(p_org, array['owner']) then raise exception 'Seul le propriétaire règle les alertes antifraude.'; end if;
  v := jsonb_build_object(
    'enabled', coalesce((p_rules->>'enabled')::boolean, true),
    'discount_count', least(greatest(coalesce((p_rules->>'discount_count')::int, 3), 1), 50),
    'discount_days', least(greatest(coalesce((p_rules->>'discount_days')::int, 7), 1), 90),
    'gap_count', least(greatest(coalesce((p_rules->>'gap_count')::int, 3), 1), 50),
    'gap_days', least(greatest(coalesce((p_rules->>'gap_days')::int, 30), 1), 180),
    'room_without_booking', coalesce((p_rules->>'room_without_booking')::boolean, true));
  perform set_config('app.fraud_rules', 'on', true);
  update public.organizations set fraud_rules = v where id = p_org;
  return v;
end $$;
revoke all on function public.set_fraud_rules(uuid, jsonb) from public, anon;
grant execute on function public.set_fraud_rules(uuid, jsonb) to authenticated;

-- Les seuils ne se modifient que par set_fraud_rules (le gérant ne peut pas désactiver les alertes qui le concernent)
create or replace function public.protect_fraud_rules() returns trigger language plpgsql set search_path to '' as $$
begin
  if new.fraud_rules is distinct from old.fraud_rules and coalesce(current_setting('app.fraud_rules', true), '') <> 'on' and not public._platform_actor() then
    raise exception 'Les alertes antifraude se règlent dans Contrôle par le propriétaire.';
  end if;
  return new;
end $$;
drop trigger if exists trg_org_fraud_rules on public.organizations;
create trigger trg_org_fraud_rules before update on public.organizations for each row execute function public.protect_fraud_rules();
