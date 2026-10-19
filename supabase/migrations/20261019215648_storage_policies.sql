-- Each user may read/write only objects under a folder named after their user id.
create policy "backups: users manage own folder"
on storage.objects
for all
to authenticated
using (
  bucket_id = 'backups'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'backups'
  and (storage.foldername(name))[1] = auth.uid()::text
);