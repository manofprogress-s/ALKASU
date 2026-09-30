-- ALKASU 0008 — İşlem geçmişi okuma (yönetici)
create or replace function public.audit_log(p_business uuid, p_limit integer default 100, p_offset integer default 0,
                                            p_action text default null, p_user uuid default null)
returns table(id bigint, at timestamptz, user_id uuid, user_name text, action text, table_name text, record_id text,
              old_data jsonb, new_data jsonb)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici');
  return query
  select l.id, l.at, l.user_id, m.display_name, l.action, l.table_name, l.record_id, l.old_data, l.new_data
    from audit.log l
    left join public.memberships m on m.user_id = l.user_id and m.business_id = l.business_id
   where l.business_id = p_business
     and (p_action is null or l.action = p_action)
     and (p_user is null or l.user_id = p_user)
   order by l.id desc
   limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $$;

select app.apply_grants();
