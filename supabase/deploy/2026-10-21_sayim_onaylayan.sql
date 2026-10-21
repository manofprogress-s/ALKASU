-- 21.10.2026: sayım onaylayanlar (0036); şimdilik yalnızca Enes.
begin;
-- ALKASU 0036 — Sayım onaylayanlar ayarı (kullanıcı 21.10: "şimdilik sadece benim onayım yeterli, sonra Ayhan'ı ekleyeceğiz")
-- Kural: BUSINESS_RULES T-04/6 · Karar: D-095
-- app_settings.count_approvers: boşsa tüm aktif yöneticiler (en fazla 2 onay); doluysa yalnızca listedekiler onaylar ve
-- gereken onay sayısı listedeki aktif yönetici sayısıdır. Yönetici Ayarlar'dan değiştirir.

alter table public.app_settings add column if not exists count_approvers uuid[] not null default '{}';

create or replace function app.is_count_approver(p_business uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.memberships m where m.business_id = p_business and m.user_id = p_user and m.active and m.role = 'yonetici')
     and (coalesce(cardinality((select count_approvers from public.app_settings where business_id = p_business)), 0) = 0
          or exists (select 1 from public.app_settings s where s.business_id = p_business and p_user = any(s.count_approvers)))
$$;

create or replace function app.count_approvals_required(p_business uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when coalesce(cardinality((select count_approvers from public.app_settings where business_id = p_business)), 0) > 0
      then greatest(1, (select count(*) from public.memberships m where m.business_id = p_business and m.active and m.role = 'yonetici'
                         and exists (select 1 from public.app_settings s where s.business_id = p_business and m.user_id = any(s.count_approvers)))::int)
    else greatest(1, least(2, (select count(*) from public.memberships where business_id = p_business and active and role = 'yonetici')::int))
  end
$$;

create or replace function public.stock_count_preview(p_count uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'depo');
  return jsonb_build_object(
    'status', c.status, 'no', c.no,
    'required', app.count_approvals_required(c.business_id),
    'submitted_at', c.submitted_at,
    'submitted_by', (select display_name from public.memberships where business_id = c.business_id and user_id = c.submitted_by limit 1),
    'approvals', coalesce((select jsonb_agg(jsonb_build_object('user_id', a.user_id, 'at', a.approved_at,
                                    'name', (select display_name from public.memberships m where m.business_id = c.business_id and m.user_id = a.user_id limit 1))
                                    order by a.approved_at)
                             from public.stock_count_approvals a where a.count_id = p_count), '[]'::jsonb),
    'approvers', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', m.display_name) order by m.display_name)
                             from public.memberships m where m.business_id = c.business_id and m.active and m.role = 'yonetici'
                              and app.is_count_approver(c.business_id, m.user_id)), '[]'::jsonb),
    'summary', c.summary,
    'lines', app.stock_count_diff(p_count));
end $$;

create or replace function public.approve_stock_count(p_count uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts; l record; v_moved int; v_diff int; v_n int := 0; v_total int := 0; v_have int; v_need int;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici');
  if not app.is_count_approver(c.business_id, auth.uid()) then
    raise exception 'Sayım onayı için yetkili değilsiniz (Ayarlar → Sayım onaylayanlar)' using errcode = '42501';
  end if;
  if c.status = 'acik' then raise exception 'Sayım henüz onaya gönderilmedi' using errcode = 'P0001'; end if;
  if c.status <> 'onayda' then raise exception 'Sayım zaten kapanmış' using errcode = 'P0001'; end if;
  if exists (select 1 from public.stock_count_approvals where count_id = p_count and user_id = auth.uid()) then
    raise exception 'Bu sayımı zaten onayladınız; diğer yöneticinin onayı bekleniyor' using errcode = 'P0001';
  end if;
  insert into public.stock_count_approvals(count_id, business_id, user_id) values (p_count, c.business_id, auth.uid());
  perform app.audit(c.business_id, 'sayim_onay_ver', 'stock_counts', p_count::text, null, null);
  select count(*) into v_have from public.stock_count_approvals a where a.count_id = p_count and app.is_count_approver(c.business_id, a.user_id);
  v_need := app.count_approvals_required(c.business_id);
  if v_have < v_need then
    return jsonb_build_object('applied', false, 'approvals', v_have, 'required', v_need);
  end if;

  for l in select * from public.stock_count_lines where count_id = p_count and counted_qty is not null order by product_id loop
    select coalesce(sum(qty), 0) into v_moved from public.stock_movements
     where product_id = l.product_id and location_id = c.location_id and id > c.snapshot_movement_id;
    v_diff := l.counted_qty - (l.snapshot_qty + v_moved);
    update public.stock_count_lines set moved_during = v_moved, diff = v_diff where count_id = p_count and product_id = l.product_id;
    if v_diff <> 0 then
      perform app.post_stock(c.business_id, c.location_id, l.product_id, v_diff, 'sayim_duzeltme', 'stock_count', p_count);
      v_n := v_n + 1; v_total := v_total + v_diff;
    end if;
  end loop;
  update public.stock_counts set status = 'onaylandi', decided_by = auth.uid(), decided_at = now() where id = p_count;
  perform app.audit(c.business_id, 'sayim_onay', 'stock_counts', p_count::text, null,
                    jsonb_build_object('adjusted_products', v_n, 'net_diff', v_total, 'approvals', v_have));
  return jsonb_build_object('applied', true, 'approvals', v_have, 'required', v_need, 'adjusted_products', v_n, 'net_diff', v_total);
end $$;

-- Yönetici: sayım onaylayanları belirler (boş liste = tüm yöneticiler, en fazla 2 onay)
create or replace function public.set_count_approvers(p_business uuid, p_users uuid[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old uuid[];
begin
  perform app.require_role(p_business, 'yonetici');
  if exists (select 1 from unnest(coalesce(p_users, '{}')) u
              where not exists (select 1 from public.memberships m where m.business_id = p_business and m.user_id = u and m.active and m.role = 'yonetici')) then
    raise exception 'Yalnızca aktif yöneticiler sayım onaylayıcısı olabilir' using errcode = '22023';
  end if;
  select count_approvers into v_old from public.app_settings where business_id = p_business;
  update public.app_settings set count_approvers = coalesce((select array_agg(distinct u) from unnest(p_users) u), '{}'), updated_at = now()
   where business_id = p_business;
  perform app.audit(p_business, 'sayim_onaylayanlar', 'app_settings', p_business::text,
                    jsonb_build_object('count_approvers', v_old), jsonb_build_object('count_approvers', p_users));
  return jsonb_build_object('required', app.count_approvals_required(p_business));
end $$;

select app.apply_grants();
do $$
declare v_n int; v_u uuid; v_b uuid;
begin
  select count(*), min(user_id::text)::uuid, min(business_id::text)::uuid into v_n, v_u, v_b
    from public.memberships where role = 'yonetici' and active and display_name = 'Enes Karakaya';
  if v_n <> 1 then raise exception 'Enes yönetici kaydı tek değil: %', v_n; end if;
  update public.app_settings set count_approvers = array[v_u], updated_at = now() where business_id = v_b;
end $$;
select 'SONUC: onaylayan ayarlandi, gereken onay=' || app.count_approvals_required(business_id) || ', liste=' || cardinality(count_approvers) from public.app_settings;
commit;
