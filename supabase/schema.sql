-- 모도: 초대 링크 코드(grp)별로 나뉜 공유 문서 저장소
create table public.modo_docs (
  grp text not null,
  col text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (grp, col, id),
  constraint modo_docs_grp_ok check (grp ~ '^[A-Za-z0-9_-]{12,64}$'),
  constraint modo_docs_col_ok check (col in ('members', 'busy', 'events', 'votes', 'meta')),
  constraint modo_docs_id_ok check (id ~ '^[A-Za-z0-9_.:@+~-]{1,200}$'),
  constraint modo_docs_data_obj check (jsonb_typeof(data) = 'object'),
  constraint modo_docs_data_size check (pg_column_size(data) <= 65536)
);
create index modo_docs_grp_updated_idx on public.modo_docs (grp, updated_at);

create or replace function public.modo_touch() returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;
create trigger modo_docs_touch before insert or update on public.modo_docs for each row execute function public.modo_touch();

create or replace function public.modo_req_group() returns text language sql stable set search_path = '' as $$
  select nullif(nullif(current_setting('request.headers', true), '')::json ->> 'x-modo-group', '');
$$;
create or replace function public.modo_cur_group() returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('modo.grp', true), ''), public.modo_req_group());
$$;

alter table public.modo_docs enable row level security;
create policy modo_docs_select on public.modo_docs for select to anon, authenticated using (grp = (select public.modo_cur_group()));
create policy modo_docs_insert on public.modo_docs for insert to anon, authenticated with check (grp = (select public.modo_cur_group()));
create policy modo_docs_update on public.modo_docs for update to anon, authenticated using (grp = (select public.modo_cur_group())) with check (grp = (select public.modo_cur_group()));
create policy modo_docs_delete on public.modo_docs for delete to anon, authenticated using (grp = (select public.modo_cur_group()));
revoke all on table public.modo_docs from anon, authenticated;
grant select, insert, update, delete on table public.modo_docs to anon, authenticated;

create or replace function public.modo_use_group(p_grp text) returns void language plpgsql set search_path = '' as $$
begin
  if p_grp is null or p_grp !~ '^[A-Za-z0-9_-]{12,64}$' then
    raise exception 'invalid group' using errcode = '22023';
  end if;
  perform set_config('modo.grp', p_grp, true);
end;
$$;

create or replace function public.modo_pull(p_grp text, p_since timestamptz default null)
returns table (col text, id text, data jsonb, deleted boolean, updated_at timestamptz)
language plpgsql volatile set search_path = '' as $$
#variable_conflict use_column
begin
  perform public.modo_use_group(p_grp);
  return query
    select d.col, d.id, d.data, d.deleted, d.updated_at from public.modo_docs d
     where d.grp = p_grp and (p_since is null or d.updated_at > p_since)
     order by d.updated_at limit 5000;
end;
$$;

create or replace function public.modo_put(p_grp text, p_col text, p_id text, p_data jsonb, p_deleted boolean default false)
returns void language plpgsql volatile set search_path = '' as $$
begin
  perform public.modo_use_group(p_grp);
  insert into public.modo_docs (grp, col, id, data, deleted)
  values (p_grp, p_col, p_id, coalesce(p_data, '{}'::jsonb), coalesce(p_deleted, false))
  on conflict (grp, col, id) do update set data = excluded.data, deleted = excluded.deleted;
end;
$$;

create or replace function public.modo_patch(p_grp text, p_col text, p_id text, p_patch jsonb)
returns void language plpgsql volatile set search_path = '' as $$
begin
  perform public.modo_use_group(p_grp);
  if jsonb_typeof(p_patch) is distinct from 'object' then
    raise exception 'patch must be an object' using errcode = '22023';
  end if;
  update public.modo_docs as d set data = d.data || p_patch
   where d.grp = p_grp and d.col = p_col and d.id = p_id and not d.deleted;
end;
$$;

revoke all on function public.modo_use_group(text) from public;
revoke all on function public.modo_pull(text, timestamptz) from public;
revoke all on function public.modo_put(text, text, text, jsonb, boolean) from public;
revoke all on function public.modo_patch(text, text, text, jsonb) from public;
grant execute on function public.modo_use_group(text) to anon, authenticated;
grant execute on function public.modo_pull(text, timestamptz) to anon, authenticated;
grant execute on function public.modo_put(text, text, text, jsonb, boolean) to anon, authenticated;
grant execute on function public.modo_patch(text, text, text, jsonb) to anon, authenticated;
