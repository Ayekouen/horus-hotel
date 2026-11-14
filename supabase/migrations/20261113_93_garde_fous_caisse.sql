-- 93 · Garde-fous de caisse et de facturation (audit du 13/11/2026).
-- Contrôles faits par la base, quel que soit l'appareil ou la version de l'application :
--   • encaissement en double (même séjour, même montant, même moyen, moins de 2 minutes) refusé ;
--   • encaissement supérieur au solde du séjour refusé ;
--   • remboursement limité au montant payé sur le séjour, réservé au gérant et au propriétaire
--     (sauf annulation d'un encaissement par une personne autorisée), avec alerte au propriétaire ;
--   • transfert ou sortie d'espèces supérieurs au contenu de la caisse refusés ;
--   • une seule facture par séjour : une nouvelle facture n'est émise que si le séjour a changé, avec un avoir sur la précédente ;
--   • alerte au propriétaire en cas de départ avec impayé et de no-show avec trop-perçu.
-- Appliquée le 13/11/2026. Ajouts uniquement : aucune donnée existante n'est modifiée. Les paiements en ligne (serveur) ne sont pas concernés.

-- Montants affichés avec public._fcfa (fonction existante, espace des milliers)

-- Espèces présentes dans une session de caisse (même calcul que l'écran Caisse)
create or replace function public._session_cash(p_session uuid) returns numeric
language sql stable security definer set search_path to '' as $$
  select coalesce((select s.opening_balance from public.cash_sessions s where s.id = p_session), 0)
       + coalesce(sum(m.amount) filter (where m.kind in ('payment', 'income', 'transfer_in')), 0)
       - coalesce(sum(m.amount) filter (where m.kind in ('expense', 'refund', 'deposit', 'transfer_out')), 0)
  from public.cash_movements m where m.session_id = p_session and m.method = 'cash'
$$;
revoke all on function public._session_cash(uuid) from public, anon, authenticated;

create or replace function public._cash_safeguards() returns trigger
language plpgsql security definer set search_path to '' as $$
declare v_bal numeric; v_paid numeric; v_refunded numeric; v_cash numeric; v_guest text; v_role text;
begin
  -- Opérations du serveur (paiement en ligne, tâches planifiées) : non concernées
  if auth.uid() is null or public.is_service_context() then return new; end if;

  if new.kind = 'payment' and new.reservation_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('pay:' || new.reservation_id::text, 0));
    if exists (select 1 from public.cash_movements m
                where m.reservation_id = new.reservation_id and m.kind = 'payment' and m.amount = new.amount
                  and m.method is not distinct from new.method and m.created_at > now() - interval '2 minutes'
                  and (new.payment_group is null or m.payment_group is distinct from new.payment_group)) then
      raise exception 'Encaissement déjà enregistré il y a moins de 2 minutes (même montant, même moyen). Vérifiez le séjour avant de recommencer.';
    end if;
    select balance into v_bal from public.reservation_balances where id = new.reservation_id;
    if v_bal is not null and new.amount > greatest(v_bal, 0) then
      raise exception 'Montant supérieur au solde du séjour (reste à payer : % F).', public._fcfa(greatest(v_bal, 0));
    end if;
  end if;

  if new.kind = 'refund' then
    v_role := public.actor_role(new.organization_id);
    if not (coalesce(new.reference, '') like 'ANN:%' or v_role in ('owner', 'admin', 'manager')) then
      raise exception 'Seuls le gérant et le propriétaire peuvent rembourser un client.';
    end if;
    if new.reservation_id is not null then
      perform pg_advisory_xact_lock(hashtextextended('pay:' || new.reservation_id::text, 0));
      select coalesce(sum(amount) filter (where kind = 'payment'), 0), coalesce(sum(amount) filter (where kind = 'refund'), 0)
        into v_paid, v_refunded from public.cash_movements where reservation_id = new.reservation_id;
      if new.amount > v_paid - v_refunded then
        raise exception 'Remboursement supérieur au montant payé sur ce séjour (au plus % F).', public._fcfa(greatest(v_paid - v_refunded, 0));
      end if;
    end if;
    -- l'alerte au propriétaire est déjà envoyée par le journal de caisse (audit_cash_movements)
  end if;

  if new.method = 'cash' and new.session_id is not null and new.kind in ('transfer_out', 'deposit', 'refund', 'expense') then
    perform pg_advisory_xact_lock(hashtextextended('sess:' || new.session_id::text, 0));
    v_cash := public._session_cash(new.session_id);
    if new.amount > v_cash then
      raise exception 'Il n''y a que % F en espèces dans cette caisse : sortie impossible.', public._fcfa(greatest(v_cash, 0));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_05_cash_safeguards on public.cash_movements;
create trigger trg_05_cash_safeguards before insert on public.cash_movements for each row execute function public._cash_safeguards();

-- Départ avec impayé, no-show avec trop-perçu : le propriétaire est prévenu
create or replace function public._resa_money_alerts() returns trigger
language plpgsql security definer set search_path to '' as $$
declare v_bal numeric;
begin
  -- Départ avec impayé : déjà signalé par audit_reservations ; seul le no-show avec trop-perçu est ajouté
  if new.status is not distinct from old.status or new.status <> 'no_show' then return new; end if;
  select balance into v_bal from public.reservation_balances where id = new.id;
  if v_bal < 0 then
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'info', 'noshow_overpaid',
      format('No-show de %s : %s F déjà encaissés. Décidez s''il faut rembourser ou conserver l''acompte.', coalesce(new.guest_name, 'un client'), public._fcfa(-v_bal)), 'reservation', new.id);
  end if;
  return new;
end $$;
drop trigger if exists trg_zz_resa_money_alerts on public.reservations;
create trigger trg_zz_resa_money_alerts after update of status on public.reservations for each row execute function public._resa_money_alerts();

-- Facture : une seule par séjour ; si le séjour a changé, avoir sur la précédente puis nouvelle facture
create or replace function public.issue_guest_invoice(p_reservation uuid) returns uuid
language plpgsql security definer set search_path to '' as $$
declare r public.reservations; v_paid numeric; v_refund numeric; v_n bigint; v_id uuid; v_nights int; v_extras numeric; v_lines jsonb;
        prev public.guest_invoices; v_total numeric;
begin
  select * into r from public.reservations where id = p_reservation;
  if not found or not public.has_org_role(r.organization_id, array['owner','admin','manager','receptionist','accountant']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(r.organization_id);
  perform pg_advisory_xact_lock(hashtextextended('inv:' || r.id::text, 0));
  select coalesce(sum(amount) filter (where kind = 'payment'),0), coalesce(sum(amount) filter (where kind = 'refund'),0)
    into v_paid, v_refund from public.cash_movements where reservation_id = r.id;
  select coalesce(sum(total), 0) into v_extras from public.extra_sales where reservation_id = r.id and status = 'on_note';
  v_total := r.total_amount + v_extras;

  -- Dernière facture du séjour non annulée par un avoir
  select * into prev from public.guest_invoices i
   where i.reservation_id = r.id and i.kind = 'invoice'
     and not exists (select 1 from public.guest_invoices c where c.kind = 'credit_note' and c.reservation_id = r.id and c.lines @> jsonb_build_array(jsonb_build_object('ref', i.number)))
   order by i.issued_at desc limit 1;
  if prev.id is not null and prev.total = v_total and prev.paid = v_paid - v_refund then
    return prev.id;   -- rien n'a changé : on rend la même facture
  end if;
  if prev.id is not null then
    insert into public.org_counters (organization_id, name, value) values (r.organization_id, 'credit_note', 1)
      on conflict (organization_id, name) do update set value = public.org_counters.value + 1 returning value into v_n;
    insert into public.guest_invoices (organization_id, establishment_id, reservation_id, number, kind, guest_name, lines, total, paid, balance, issued_by)
    values (r.organization_id, r.establishment_id, r.id, 'A' || to_char(now(),'YYYY') || '-' || lpad(v_n::text, 5, '0'), 'credit_note', prev.guest_name,
      jsonb_build_array(jsonb_build_object('label', 'Avoir sur la facture ' || prev.number || ' (séjour modifié)', 'qty', 1, 'unit', -prev.total, 'amount', -prev.total, 'ref', prev.number)),
      -prev.total, 0, -prev.total, auth.uid());
  end if;

  v_nights := r.check_out - r.check_in;
  v_lines := jsonb_build_array(
      jsonb_build_object('label', format('Hébergement chambre %s du %s au %s', (select number from public.rooms where id = r.room_id), to_char(r.check_in,'DD/MM/YYYY'), to_char(r.check_out,'DD/MM/YYYY')), 'qty', v_nights, 'unit', r.nightly_rate, 'amount', v_nights * r.nightly_rate))
    || case when r.discount > 0 then jsonb_build_array(jsonb_build_object('label','Remise','qty',1,'unit',-r.discount,'amount',-r.discount)) else '[]'::jsonb end
    || coalesce((select jsonb_agg(jsonb_build_object('label', x.label, 'qty', x.qty, 'unit', x.unit_price, 'amount', x.total) order by x.created_at)
                 from public.extra_sales x where x.reservation_id = r.id and x.status = 'on_note'), '[]'::jsonb);
  insert into public.org_counters (organization_id, name, value) values (r.organization_id, 'invoice', 1)
    on conflict (organization_id, name) do update set value = public.org_counters.value + 1 returning value into v_n;
  insert into public.guest_invoices (organization_id, establishment_id, reservation_id, number, guest_name, lines, total, paid, balance, issued_by)
  values (r.organization_id, r.establishment_id, r.id, 'F' || to_char(now(),'YYYY') || '-' || lpad(v_n::text, 5, '0'), r.guest_name,
    v_lines, v_total, v_paid - v_refund, v_total - (v_paid - v_refund), auth.uid())
  returning id into v_id;
  return v_id;
end $$;
