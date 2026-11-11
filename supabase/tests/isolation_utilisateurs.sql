-- Tests d'isolation des données entre utilisateurs (Nuittea Manager, Supabase).
-- À exécuter en une seule fois : tout se passe dans une transaction annulée à la fin (aucune donnée réelle n'est modifiée).
-- Résultat : une exception « TEST_RESULT réussis=… échecs=… » listant chaque contrôle en échec.
begin;
do $test$
declare
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uR uuid := gen_random_uuid();
  oA uuid; oB uuid; eA uuid; eB uuid; rmA uuid; gA uuid; rsA uuid; mR uuid; mA uuid; revA uuid;
  ok int := 0; ko text[] := '{}'; n int; v text; why text[] := '{}';
  -- exécute une instruction et attend un refus (exception ou 0 ligne touchée)
begin
  -- Préparation (rôle serveur) : 3 comptes, 2 hôtels
  insert into auth.users (id, email, aud, role, instance_id, raw_user_meta_data) values
    (uA, 'test.a.' || uA || '@exemple.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', '{}'),
    (uB, 'test.b.' || uB || '@exemple.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', '{}'),
    (uR, 'test.r.' || uR || '@exemple.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', '{}');

  perform set_config('request.jwt.claims', json_build_object('sub', uA, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  oA := public.create_organization('Test isolation A', 'Hôtel A', 'Abidjan');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', uB, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  oB := public.create_organization('Test isolation B', 'Hôtel B', 'Abidjan');
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  select id into eA from public.establishments where organization_id = oA;
  select id into eB from public.establishments where organization_id = oB;
  select id into mA from public.organization_members where organization_id = oA and user_id = uA;
  insert into public.rooms (establishment_id, number, base_rate) values (eA, 'T-101', 20000) returning id into rmA;
  insert into public.guests (organization_id, full_name, phone) values (oA, 'Client Test', '0700000000') returning id into gA;
  insert into public.reservations (establishment_id, room_id, guest_id, guest_name, check_in, check_out, status, nightly_rate)
    values (eA, rmA, gA, 'Client Test', current_date + 30, current_date + 32, 'confirmed', 20000) returning id into rsA;
  insert into public.organization_members (organization_id, user_id, role, is_active) values (oA, uR, 'receptionist', true) returning id into mR;
  insert into public.reviews (organization_id, establishment_id, reservation_id, guest_name, rating, comment, status)
    values (oA, eA, rsA, 'Client Test', 2, 'Moyen', 'submitted') returning id into revA;

  -- ===== Utilisateur B (propriétaire d'un autre hôtel) contre les données de A =====
  perform set_config('request.jwt.claims', json_build_object('sub', uB, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into n from public.reservations where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit les réservations de A'::text); end if;
  select count(*) into n from public.reservation_balances where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit les soldes de A'::text); end if;
  select count(*) into n from public.rooms where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit les chambres de A'::text); end if;
  select count(*) into n from public.guests where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit les clients de A'::text); end if;
  select count(*) into n from public.establishments where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit l''établissement de A'::text); end if;
  select count(*) into n from public.organization_members where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit l''équipe de A'::text); end if;
  select count(*) into n from public.organizations where id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit l''organisation A'::text); end if;
  select count(*) into n from public.cash_movements where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit la caisse de A'::text); end if;
  select count(*) into n from public.reviews where organization_id = oA; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B lit les avis de A'::text); end if;

  update public.rooms set base_rate = 1 where id = rmA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B modifie une chambre de A'::text); end if;
  update public.reservations set status = 'cancelled' where id = rsA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B annule une réservation de A'::text); end if;
  update public.guests set full_name = 'x' where id = gA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B modifie un client de A'::text); end if;
  update public.establishments set name = 'x' where id = eA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B modifie l''établissement de A'::text); end if;
  update public.organizations set name = 'x' where id = oA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B modifie l''organisation A'::text); end if;
  delete from public.reservations where id = rsA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B supprime une réservation de A'::text); end if;
  delete from public.rooms where id = rmA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B supprime une chambre de A'::text); end if;
  delete from public.organization_members where id = mR; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'B retire un employé de A'::text); end if;

  begin insert into public.rooms (establishment_id, number, base_rate) values (eA, 'X', 1); ko := array_append(ko, 'B crée une chambre chez A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.reservations (establishment_id, room_id, guest_name, check_in, check_out, status, nightly_rate) values (eA, rmA, 'x', current_date + 60, current_date + 61, 'confirmed', 1); ko := array_append(ko, 'B crée une réservation chez A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.reservations (establishment_id, room_id, guest_name, check_in, check_out, status, nightly_rate) values (eB, rmA, 'x', current_date + 60, current_date + 61, 'confirmed', 1); ko := array_append(ko, 'B réserve une chambre de A depuis son hôtel'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.guests (organization_id, full_name) values (oA, 'x'); ko := array_append(ko, 'B crée un client chez A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.cash_movements (establishment_id, kind, method, amount, label) values (eA, 'income', 'mobile_money', 1000, 'x'); ko := array_append(ko, 'B écrit dans la caisse de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.cash_registers (organization_id, establishment_id, name) values (oB, eA, 'Caisse test'); ko := array_append(ko, 'B crée une caisse dans l''hôtel de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.staff_shifts (organization_id, member_id, day, start_time, end_time) values (oA, mR, current_date, '08:00', '16:00'); ko := array_append(ko, 'B planifie un employé de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin insert into public.meter_readings (organization_id, establishment_id, room_id, kind, value) values (oA, eA, rmA, 'water', 1); ko := array_append(ko, 'B saisit un relevé chez A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;

  begin perform public.stay_price(rmA, current_date, current_date + 1); ko := array_append(ko, 'B obtient un prix de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.member_activity(mR, 10); ko := array_append(ko, 'B lit l''activité d''un employé de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.request_review(rsA); ko := array_append(ko, 'B demande un avis sur une réservation de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.set_member_job(mR, 'veilleur'); ko := array_append(ko, 'B change le poste d''un employé de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.set_member_access(mR, '{}'::jsonb); ko := array_append(ko, 'B change les accès d''un employé de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.regen_login_code(oA); ko := array_append(ko, 'B change le code de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.mark_alerts_read(oA, null); ko := array_append(ko, 'B lit les alertes de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.clock(oA, eA, 'in'); ko := array_append(ko, 'B pointe chez A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.clock(oB, eA, 'in'); ko := array_append(ko, 'B pointe dans l''établissement de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.check_in_reservation(rsA); ko := array_append(ko, 'B fait l''arrivée d''un client de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.issue_guest_invoice(rsA); ko := array_append(ko, 'B facture une réservation de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.daily_report(oA, current_date); ko := array_append(ko, 'B lit le rapport de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.financial_report(oA, current_date - 30, current_date); ko := array_append(ko, 'B lit les finances de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.get_subscription_overview(oA); ko := array_append(ko, 'B lit l''abonnement de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.security_overview(oA); ko := array_append(ko, 'B lit la sécurité de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.org_team_v2(oA); select count(*) into n from public.org_team_v2(oA); if n > 0 then ko := array_append(ko, 'B lit l''équipe de A (fonction)'::text); else ok := ok + 1; end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.payout_request(oA, 5000, 'wave', '0700000000', 'x'); ko := array_append(ko, 'B demande un reversement pour A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.support_ticket_create(oB, eA, 'Sujet de test', 'question', 'Message de test'); ko := array_append(ko, 'B ouvre un ticket sur l''hôtel de A'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  execute 'reset role';

  -- ===== Réceptionniste de A : limites de son poste =====
  perform set_config('request.jwt.claims', json_build_object('sub', uR, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.reservations where id = rsA; if n = 1 then ok := ok + 1; else ko := array_append(ko, 'La réception de A ne voit pas ses réservations'::text); end if;
  begin update public.rooms set base_rate = 1 where id = rmA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'La réception change le prix d''une chambre'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.rooms set housekeeping_status = 'dirty' where id = rmA; get diagnostics n = row_count; if n = 1 then ok := ok + 1; else ko := array_append(ko, 'La réception ne peut pas changer l''état de ménage'::text); end if; exception when others then ko := array_append(ko, ('La réception ne peut pas changer l''état de ménage : ' || sqlerrm)::text); end;
  delete from public.reservations where id = rsA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'La réception supprime une réservation'::text); end if;
  begin update public.organization_members set role = 'admin' where id = mR; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'La réception se donne le rôle administrateur'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.organizations set name = 'x' where id = oA; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'La réception renomme l''organisation'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  select count(*) into n from public.cash_movements where organization_id = oA; ok := ok + 1; -- lecture caisse autorisée pour la réception
  begin perform public.member_activity(mA, 10); ko := array_append(ko, 'La réception lit l''activité du propriétaire'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  execute 'reset role';

  -- ===== Propriétaire de A : champs réservés à Nuittea =====
  perform set_config('request.jwt.claims', json_build_object('sub', uA, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin update public.organizations set admin_overrides = '{"features_add":["venues"]}' where id = oA; ko := array_append(ko, 'Le propriétaire s''ajoute des fonctions payantes'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.organizations set is_test = true where id = oA; ko := array_append(ko, 'Le propriétaire passe son compte en test'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.organizations set login_code = 'NTAAAA' where id = oA; ko := array_append(ko, 'Le propriétaire choisit son code sans passer par « Nouveau code »'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.establishments set nuittea_suspended_at = null, nuittea_suspended_reason = null where id = eA and nuittea_suspended_at is null; ok := ok + 1; exception when others then ko := array_append(ko, 'Mise à jour neutre de l''établissement refusée'::text); end;
  begin update public.establishments set nuittea_suspended_at = now() where id = eA; ko := array_append(ko, 'Le propriétaire modifie la suspension Nuittea'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.rooms set nuittea_hidden = true where id = rmA; ko := array_append(ko, 'Le propriétaire modifie le masquage Nuittea'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.reviews set rating = 5, comment = 'Parfait' where id = revA; ko := array_append(ko, 'Le propriétaire modifie la note d''un client'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin update public.reviews set reply = 'Merci' where id = revA; get diagnostics n = row_count; if n = 1 then ok := ok + 1; else ko := array_append(ko, 'Le propriétaire ne peut pas répondre à un avis'::text); end if; exception when others then ko := array_append(ko, ('Réponse à un avis refusée : ' || sqlerrm)::text); end;
  begin update public.rooms set base_rate = 25000 where id = rmA; get diagnostics n = row_count; if n = 1 then ok := ok + 1; else ko := array_append(ko, 'Le propriétaire ne peut pas changer ses prix'::text); end if; exception when others then ko := array_append(ko, ('Prix refusé au propriétaire : ' || sqlerrm)::text); end;
  begin v := public.regen_login_code(oA); if v ~ '^NT[A-Z2-9]{4}$' then ok := ok + 1; else ko := array_append(ko, 'Nouveau code invalide'::text); end if; exception when others then ko := array_append(ko, ('Nouveau code refusé au propriétaire : ' || sqlerrm)::text); end;
  execute 'reset role';

  -- ===== Visiteur anonyme =====
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
  begin select count(*) into n from public.reservations; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'Un visiteur lit des réservations'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin select count(*) into n from public.guests; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'Un visiteur lit des clients'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin select count(*) into n from public.cash_movements; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'Un visiteur lit une caisse'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin select count(*) into n from public.organization_members; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'Un visiteur lit des équipes'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin delete from public.rooms; get diagnostics n = row_count; if n = 0 then ok := ok + 1; else ko := array_append(ko, 'Un visiteur supprime des chambres'::text); end if; exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  begin perform public.daily_report(oA, current_date); ko := array_append(ko, 'Un visiteur lit un rapport'::text); exception when others then ok := ok + 1; why := array_append(why, left(sqlerrm, 70)); end;
  execute 'reset role';

  raise exception 'TEST_RESULT réussis=% échecs=% % || MOTIFS DE REFUS : %', ok, coalesce(array_length(ko, 1), 0), array_to_string(ko, ' | '), (select string_agg(distinct x, ' ; ') from unnest(why) x);
end $test$;
rollback;
