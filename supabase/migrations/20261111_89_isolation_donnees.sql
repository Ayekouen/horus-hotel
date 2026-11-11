-- 89 · Contrôles d'accès côté serveur : champs réservés à Nuittea, cohérence établissement / organisation,
-- droits fins par rôle. Ajouts de gardes uniquement : aucune donnée existante n'est modifiée.

-- Acteur plateforme : tâches serveur, administrateur ou membre de l'équipe Nuittea (console)
create or replace function public._platform_actor() returns boolean language sql stable security definer set search_path to '' as $$
  select public.is_service_context() or public.is_platform_admin() or coalesce(public.staff_can('dashboard'), false)
$$;
revoke all on function public._platform_actor() from public, anon;
grant execute on function public._platform_actor() to authenticated;

-- 1. Organisations : champs réservés à la plateforme (test, dérogations de formule) et codes de connexion
create or replace function public.protect_org_platform_fields() returns trigger language plpgsql set search_path to '' as $$
begin
  if public._platform_actor() then return new; end if;
  if new.is_test is distinct from old.is_test or new.admin_overrides is distinct from old.admin_overrides
     or new.created_by is distinct from old.created_by then
    raise exception 'Modification réservée à l''équipe Nuittea.';
  end if;
  if new.login_code is distinct from old.login_code and coalesce(current_setting('app.login_code', true), '') <> 'on' then
    raise exception 'Le code de l''établissement se change avec « Nouveau code ».';
  end if;
  if new.staff_code is distinct from old.staff_code and coalesce(current_setting('app.staff_code', true), '') <> 'on' then
    raise exception 'Le code interne du personnel ne se modifie pas directement.';
  end if;
  return new;
end $$;
drop trigger if exists trg_org_platform_fields on public.organizations;
create trigger trg_org_platform_fields before update on public.organizations for each row execute function public.protect_org_platform_fields();

create or replace function public.regen_login_code(p_org uuid) returns text language plpgsql security definer set search_path to '' as $$
declare v text;
begin
  if not public.has_org_role(p_org, array['owner', 'admin']) then raise exception 'Accès refusé.'; end if;
  v := public._gen_login_code();
  perform set_config('app.login_code', 'on', true);
  update public.organizations set login_code = v where id = p_org;
  perform set_config('app.login_code', '', true);
  return v;
end $$;

do $$ declare d text; begin
  d := pg_get_functiondef('public.set_staff_code(uuid,text)'::regprocedure);
  if position('app.staff_code' in d) = 0 then
    d := replace(d, '  update public.organizations set staff_code = v where id = p_org;',
      '  perform set_config(''app.staff_code'', ''on'', true);' || chr(10) || '  update public.organizations set staff_code = v where id = p_org;' || chr(10) || '  perform set_config(''app.staff_code'', '''', true);');
    execute d;
  end if;
end $$;

-- 2. Établissements : la suspension décidée par Nuittea ne peut être levée que par Nuittea
create or replace function public.protect_est_platform_fields() returns trigger language plpgsql set search_path to '' as $$
begin
  if public._platform_actor() then return new; end if;
  if (new.nuittea_suspended_at, new.nuittea_suspended_reason, new.nuittea_suspended_by)
     is distinct from (old.nuittea_suspended_at, old.nuittea_suspended_reason, old.nuittea_suspended_by) then
    raise exception 'La suspension sur Nuittea.com est gérée par l''équipe Nuittea.';
  end if;
  if new.organization_id is distinct from old.organization_id then raise exception 'Modification interdite.'; end if;
  return new;
end $$;
drop trigger if exists trg_est_platform_fields on public.establishments;
create trigger trg_est_platform_fields before update on public.establishments for each row execute function public.protect_est_platform_fields();

-- 3. Chambres : masquage par la modération réservé à Nuittea ; réception et ménage ne changent que l'état de ménage
create or replace function public.protect_room_fields() returns trigger language plpgsql set search_path to '' as $$
begin
  if public._platform_actor() then return new; end if;
  if (new.nuittea_hidden, new.nuittea_hidden_reason) is distinct from (old.nuittea_hidden, old.nuittea_hidden_reason) then
    raise exception 'Le masquage d''une chambre sur Nuittea.com est géré par l''équipe Nuittea.';
  end if;
  if not public.has_org_role(old.organization_id, array['owner', 'admin', 'manager'])
     and (to_jsonb(new) - array['housekeeping_status', 'updated_at']) is distinct from (to_jsonb(old) - array['housekeeping_status', 'updated_at']) then
    raise exception 'Votre poste permet seulement de changer l''état de ménage.';
  end if;
  return new;
end $$;
drop trigger if exists trg_room_fields on public.rooms;
create trigger trg_room_fields before update on public.rooms for each row execute function public.protect_room_fields();

-- 4. Avis : l'établissement peut répondre et choisir l'affichage, jamais modifier la note ni le texte du client
create or replace function public.protect_review_fields() returns trigger language plpgsql set search_path to '' as $$
begin
  -- Le dépôt de l'avis par le client (lien ou Nuittea.com) passe par des fonctions dédiées : seule l'équipe de l'hôtel est restreinte ici
  if public._platform_actor() or not public.is_org_member(old.organization_id) then return new; end if;
  if (to_jsonb(new) - array['reply', 'is_published']) is distinct from (to_jsonb(old) - array['reply', 'is_published']) then
    raise exception 'La note et le commentaire du client ne peuvent pas être modifiés.';
  end if;
  if new.is_published and not old.is_published and old.moderated_at is not null then
    raise exception 'Cet avis a été masqué par la modération Nuittea.';
  end if;
  return new;
end $$;
drop trigger if exists trg_review_fields on public.reviews;
create trigger trg_review_fields before update on public.reviews for each row execute function public.protect_review_fields();

-- 5. Caisses : l'organisation est toujours celle de l'établissement
drop trigger if exists trg_00_creg_sync on public.cash_registers;
create trigger trg_00_creg_sync before insert or update on public.cash_registers for each row execute function public.sync_org_from_establishment();

-- 6. Shifts : l'établissement doit appartenir à l'organisation
drop policy if exists ss_write on public.staff_shifts;
create policy ss_write on public.staff_shifts for all to authenticated
  using ((select public.has_org_role(staff_shifts.organization_id, array['owner', 'admin', 'manager'])))
  with check ((select public.has_org_role(staff_shifts.organization_id, array['owner', 'admin', 'manager']))
    and exists (select 1 from public.organization_members m where m.id = staff_shifts.member_id and m.organization_id = staff_shifts.organization_id)
    and (staff_shifts.establishment_id is null or exists (select 1 from public.establishments e where e.id = staff_shifts.establishment_id and e.organization_id = staff_shifts.organization_id)));

-- 7. Pointage et assistance : l'établissement transmis doit appartenir à l'organisation
do $$ declare d text; begin
  d := pg_get_functiondef('public.clock(uuid,uuid,text)'::regprocedure);
  if position('Établissement inconnu' in d) = 0 then
    d := replace(d, $r$  if not public.is_org_member(p_org) then raise exception 'Accès refusé.'; end if;$r$,
      $r$  if not public.is_org_member(p_org) then raise exception 'Accès refusé.'; end if;
  if p_est is not null and not exists (select 1 from public.establishments where id = p_est and organization_id = p_org) then raise exception 'Établissement inconnu.'; end if;$r$);
    execute d;
  end if;
  d := pg_get_functiondef('public.support_ticket_create(uuid,uuid,text,text,text)'::regprocedure);
  if position('Établissement inconnu' in d) = 0 then
    d := replace(d, $r$  if not public.is_org_member(p_org) then raise exception 'Accès refusé.'; end if;$r$,
      $r$  if not public.is_org_member(p_org) then raise exception 'Accès refusé.'; end if;
  if p_est is not null and not exists (select 1 from public.establishments where id = p_est and organization_id = p_org) then raise exception 'Établissement inconnu.'; end if;$r$);
    execute d;
  end if;
end $$;
