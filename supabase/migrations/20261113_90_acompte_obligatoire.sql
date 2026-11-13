-- 90 · Acompte obligatoire pour les réservations faites sur Nuittea.com (réglage par établissement).
-- Sans paiement de l'acompte dans le délai, la réservation en ligne est annulée automatiquement et la chambre libérée.
-- Ajouts uniquement : les réservations existantes ne sont pas concernées.

alter table public.establishments add column if not exists online_deposit_required boolean not null default false;
alter table public.establishments add column if not exists online_deposit_hours int not null default 2 check (online_deposit_hours between 1 and 48);
alter table public.reservations add column if not exists payment_due_at timestamptz;
create index if not exists reservations_payment_due_idx on public.reservations (payment_due_at) where payment_due_at is not null;

-- Politique affichée sur Nuittea.com
create or replace function public.market_deposit_policy(p_slug text) returns jsonb
language sql stable security definer set search_path to '' as $$
  select coalesce((select jsonb_build_object('required', e.online_deposit_required, 'hours', e.online_deposit_hours, 'pct', 30)
                     from public.establishments e where e.slug = lower(p_slug) and e.is_active), jsonb_build_object('required', false))
$$;
revoke all on function public.market_deposit_policy(text) from public;
grant execute on function public.market_deposit_policy(text) to anon, authenticated;

-- Échéance de paiement posée à la création d'une réservation Nuittea.com
create or replace function public._resa_deposit_due() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_req boolean; v_h int;
begin
  if new.source = 'naya' then
    select online_deposit_required, online_deposit_hours into v_req, v_h from public.establishments where id = new.establishment_id;
    if v_req then new.payment_due_at := now() + make_interval(hours => coalesce(v_h, 2)); end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_05_resa_deposit_due on public.reservations;
create trigger trg_05_resa_deposit_due before insert on public.reservations for each row execute function public._resa_deposit_due();

-- Paiement reçu : l'échéance est levée
create or replace function public._resa_deposit_paid() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.kind = 'payment' and new.reservation_id is not null then
    update public.reservations set payment_due_at = null where id = new.reservation_id and payment_due_at is not null;
  end if;
  return new;
end $$;
drop trigger if exists trg_zz_resa_deposit_paid on public.cash_movements;
create trigger trg_zz_resa_deposit_paid after insert on public.cash_movements for each row execute function public._resa_deposit_paid();

-- Annulation automatique des réservations en ligne non payées dans le délai
create or replace function public.expire_unpaid_online_bookings() returns int
language plpgsql security definer set search_path to '' as $$
declare r record; n int := 0;
begin
  perform set_config('horus.marketplace', 'on', true);
  for r in select x.id, x.organization_id, x.establishment_id, x.guest_name, x.check_in from public.reservations x
            where x.payment_due_at < now() and x.status in ('pending', 'confirmed') and x.source = 'naya'
              and not exists (select 1 from public.cash_movements m where m.reservation_id = x.id and m.kind = 'payment') loop
    update public.reservations set status = 'cancelled', payment_due_at = null,
      notes = concat_ws(' · ', notes, 'Annulée automatiquement : acompte en ligne non payé dans le délai') where id = r.id;
    insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message)
    values (r.organization_id, r.establishment_id, 'info', 'deposit_expired',
      format('Réservation Nuittea.com de %s (arrivée le %s) annulée : acompte non payé dans le délai. La chambre est libérée.', coalesce(r.guest_name, 'un client'), to_char(r.check_in, 'DD/MM')));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.expire_unpaid_online_bookings() from public, anon, authenticated;
select cron.schedule('expire-unpaid-bookings', '*/10 * * * *', 'select public.expire_unpaid_online_bookings()')
 where not exists (select 1 from cron.job where jobname = 'expire-unpaid-bookings');
