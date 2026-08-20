INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'project-files',
    'project-files',
    false,
    10485760,
    ARRAY[
        'image/jpeg',
        'image/png',
        'image/gif',
        'application/pdf',
        'text/plain',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    ]
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Users can download files from accessible projects" ON storage.objects;
DROP POLICY IF EXISTS "Users can upload files to accessible projects" ON storage.objects;
DROP POLICY IF EXISTS "Users can update file metadata but not move between projects" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete files they have access to remove" ON storage.objects;

CREATE POLICY project_files_select ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'project-files'
        AND public.storage_path_matches_project(name)
        AND public.has_project_access(public.storage_project_id(name))
    );

CREATE POLICY project_files_insert ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'project-files'
        AND public.storage_path_matches_project(name)
        AND public.storage_uploader_id(name) = auth.uid()
        AND public.can_mutate_project_content(public.storage_project_id(name))
    );

CREATE POLICY project_files_update ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'project-files'
        AND public.has_project_access(public.storage_project_id(name))
    )
    WITH CHECK (
        bucket_id = 'project-files'
        AND public.storage_org_id(name) = public.storage_org_id(name)
        AND public.storage_path_matches_project(name)
        AND public.has_project_access(public.storage_project_id(name))
    );

CREATE POLICY project_files_delete ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'project-files'
        AND public.storage_path_matches_project(name)
        AND (
            public.storage_uploader_id(name) = auth.uid()
            OR public.can_manage_project(public.storage_project_id(name))
            OR public.can_archive_project(public.storage_project_id(name))
        )
    );

CREATE OR REPLACE FUNCTION public.prevent_storage_relocate()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.bucket_id IS DISTINCT FROM OLD.bucket_id
        OR public.storage_org_id(NEW.name) IS DISTINCT FROM public.storage_org_id(OLD.name)
        OR public.storage_project_id(NEW.name) IS DISTINCT FROM public.storage_project_id(OLD.name)
    THEN
        RAISE EXCEPTION 'Cannot move project files across organisations or projects';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_storage_relocate ON storage.objects;
CREATE TRIGGER trg_prevent_storage_relocate
    BEFORE UPDATE ON storage.objects
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_storage_relocate();
