-- Tests for 013_banners.sql (run_local.py reset 008 009 010).
-- The categories below are your REAL 39 live names (copied from the live table), so a pass proves the
-- migration's ASCII Unicode escapes match them exactly. Run via run_local.py `test`: one rolled-back
-- transaction, one PASS/FAIL line per check. `-- @include` pastes the migration in at that point.
create schema tst; grant usage on schema tst to anon, authenticated, service_role;
create table tst.log (ok boolean, name text, detail text);
grant all on tst.log to anon, authenticated, service_role;
create function tst.check(n text, cond boolean, d text default '') returns void language plpgsql as $$
begin insert into tst.log values (coalesce(cond,false), n, d); end $$;
create function tst.expect_err(n text, q text, code text) returns void language plpgsql as $$
declare m text;
begin
  begin execute q; m := 'NO ERROR'; exception when others then m := sqlerrm; end;
  insert into tst.log values (m = code, n, 'wanted ' || code || ' got ' || m);
end $$;
grant execute on all functions in schema tst to anon, authenticated, service_role;

insert into public.categories (id, name, name_ar) values ('c0000000-0000-0000-0000-000000000001', 'snacks', U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631');

-- @include 013_banners.sql

create function tst.fails(n text, q text) returns void language plpgsql as $$
declare m text;
begin
  begin execute q; m := 'NO ERROR'; exception when others then m := sqlerrm; end;
  insert into tst.log values (m <> 'NO ERROR', n, m);
end $$;
grant execute on function tst.fails(text, text) to anon, authenticated, service_role;

select tst.check('3 sample banners seeded, in order 1..3', (select count(*) = 3 and min(display_order) = 1 and max(display_order) = 3 from public.banners));
select tst.check('sample 1 opens the snacks category', (select target_type = 'category' and target_id = 'c0000000-0000-0000-0000-000000000001' from public.banners where display_order = 1));
select tst.check('the other samples are not tappable', (select count(*) = 2 and bool_and(target_id is null) from public.banners where target_type = 'none'));
select tst.check('sample images are wide Pexels photos', (select bool_and(image_url like 'https://images.pexels.com/%w=1200&h=520%') from public.banners));
select tst.check('bucket banner-images: public, 3 MiB, jpeg/png/webp',
  (select public and file_size_limit = 3145728 and cardinality(allowed_mime_types) = 3 and allowed_mime_types @> array['image/webp'] from storage.buckets where id = 'banner-images'));

-- the target must match its type
select tst.fails('category banner needs an id', $q$insert into public.banners (image_url, target_type) values ('https://x/a.jpg', 'category')$q$);
select tst.fails('category id must be a uuid', $q$insert into public.banners (image_url, target_type, target_id) values ('https://x/a.jpg', 'category', 'dairy')$q$);
select tst.fails('product id must be a uuid', $q$insert into public.banners (image_url, target_type, target_id) values ('https://x/a.jpg', 'product', 'nope')$q$);
select tst.fails('a link must be https', $q$insert into public.banners (image_url, target_type, target_id) values ('https://x/a.jpg', 'link', 'http://example.com')$q$);
select tst.fails('a link cannot be javascript:', $q$insert into public.banners (image_url, target_type, target_id) values ('https://x/a.jpg', 'link', 'javascript:alert(1)')$q$);
select tst.fails('a link cannot contain spaces', $q$insert into public.banners (image_url, target_type, target_id) values ('https://x/a.jpg', 'link', 'https://a.com/x y')$q$);
select tst.fails('"none" must not carry a target', $q$insert into public.banners (image_url, target_type, target_id) values ('https://x/a.jpg', 'none', 'https://a.com')$q$);
select tst.fails('unknown target type', $q$insert into public.banners (image_url, target_type) values ('https://x/a.jpg', 'popup')$q$);
select tst.fails('an image is required', $q$insert into public.banners (title) values ('no image')$q$);
insert into public.banners (title, image_url, target_type, target_id, display_order, is_active) values
  ('ok-link', 'https://x/a.jpg', 'link', 'https://example.com/offer?x=1', 4, true),
  ('ok-product', 'https://x/b.jpg', 'product', 'A0000000-0000-0000-0000-00000000000A', 5, true),
  ('hidden', 'https://x/c.jpg', 'none', null, 6, false);
select tst.check('valid link / product (any case uuid) banners are accepted', (select count(*) = 3 from public.banners where title in ('ok-link','ok-product','hidden')));

-- who can do what
set local role anon;
select tst.check('anon sees only active banners, not the hidden one', (select count(*) = 5 and bool_and(is_active) from public.banners));
reset role;
set local role authenticated;
select tst.check('signed-in users see only active banners', (select count(*) = 5 from public.banners));
reset role;
set local role anon;
select tst.expect_err('anon cannot insert', $q$insert into public.banners (image_url) values ('https://x/z.jpg')$q$, 'permission denied for table banners');
select tst.expect_err('anon cannot update', $q$update public.banners set title = 'x'$q$, 'permission denied for table banners');
select tst.expect_err('anon cannot delete', $q$delete from public.banners$q$, 'permission denied for table banners');
reset role;
set local role service_role;
select tst.check('the admin side (service_role) sees all, including hidden', (select count(*) = 6 from public.banners));
update public.banners set is_active = false where title = 'ok-link';
select tst.check('the admin side can edit', (select not is_active from public.banners where title = 'ok-link'));
reset role;

-- re-running: no duplicates, edits and deletes survive, bucket drift is repaired
update public.banners set title = 'edited' where display_order = 1;
delete from public.banners where display_order = 2;
update storage.buckets set public = false, file_size_limit = 1 where id = 'banner-images';
-- @include 013_banners.sql
select tst.check('re-run: nothing re-seeded, nothing duplicated', (select count(*) = 5 from public.banners));
select tst.check('re-run: an edited sample keeps its edit, a deleted one stays deleted',
  (select count(*) = 1 from public.banners where title = 'edited') and (select count(*) = 0 from public.banners where display_order = 2));
select tst.check('re-run: bucket settings repaired', (select public and file_size_limit = 3145728 from storage.buckets where id = 'banner-images'));
select tst.check('exactly one banner-images bucket', (select count(*) = 1 from storage.buckets where id = 'banner-images'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
