-- Private Broadcast topics: project:<project_id>
-- Authorisation uses the same has_project_access() predicate as table RLS.

CREATE OR REPLACE FUNCTION public.realtime_project_id(p_topic text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_topic LIKE 'project:%' THEN public.try_uuid(substr(p_topic, 9))
        ELSE NULL
    END;
$$;

CREATE OR REPLACE FUNCTION public.broadcast_project_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_project_id uuid;
    v_payload jsonb;
    v_event text;
BEGIN
    v_project_id := COALESCE(NEW.project_id, OLD.project_id);
    v_event := TG_TABLE_NAME || '_' || lower(TG_OP);

    IF TG_OP = 'DELETE' THEN
        v_payload := jsonb_build_object(
            'table', TG_TABLE_NAME,
            'op', TG_OP,
            'id', OLD.id,
            'project_id', OLD.project_id
        );
    ELSIF TG_TABLE_NAME = 'tasks' THEN
        v_payload := jsonb_build_object(
            'table', 'tasks',
            'op', TG_OP,
            'id', NEW.id,
            'project_id', NEW.project_id,
            'status', NEW.status,
            'position', NEW.position,
            'version', NEW.version
        );
    ELSE
        v_payload := jsonb_build_object(
            'table', 'comments',
            'op', TG_OP,
            'id', NEW.id,
            'project_id', NEW.project_id,
            'task_id', NEW.task_id
        );
    END IF;

    BEGIN
        PERFORM realtime.send(
            v_payload,
            v_event,
            'project:' || v_project_id::text,
            true
        );
    EXCEPTION
        WHEN undefined_function THEN
            NULL;
    END;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_tasks_broadcast ON public.tasks;
CREATE TRIGGER trg_tasks_broadcast
    AFTER INSERT OR UPDATE OR DELETE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION public.broadcast_project_change();

DROP TRIGGER IF EXISTS trg_comments_broadcast ON public.comments;
CREATE TRIGGER trg_comments_broadcast
    AFTER INSERT OR UPDATE OR DELETE ON public.comments
    FOR EACH ROW EXECUTE FUNCTION public.broadcast_project_change();

DO $$
BEGIN
    IF to_regclass('realtime.messages') IS NULL THEN
        RAISE NOTICE 'realtime.messages not present; Broadcast RLS will be applied when the table exists';
        RETURN;
    END IF;

    EXECUTE 'ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY';

    EXECUTE $sql$
        DROP POLICY IF EXISTS project_broadcast_select ON realtime.messages;
        DROP POLICY IF EXISTS project_broadcast_insert ON realtime.messages;
    $sql$;

    EXECUTE $sql$
        CREATE POLICY project_broadcast_select ON realtime.messages
            FOR SELECT TO authenticated
            USING (
                COALESCE((SELECT realtime.topic()), realtime.messages.topic) LIKE 'project:%'
                AND public.has_project_access(
                    public.realtime_project_id(
                        COALESCE((SELECT realtime.topic()), realtime.messages.topic)
                    )
                )
            )
    $sql$;

    EXECUTE $sql$
        CREATE POLICY project_broadcast_insert ON realtime.messages
            FOR INSERT TO authenticated
            WITH CHECK (
                COALESCE((SELECT realtime.topic()), realtime.messages.topic) LIKE 'project:%'
                AND public.has_project_access(
                    public.realtime_project_id(
                        COALESCE((SELECT realtime.topic()), realtime.messages.topic)
                    )
                )
            )
    $sql$;
EXCEPTION
    WHEN undefined_table OR undefined_function OR undefined_column THEN
        RAISE NOTICE 'Skipping realtime.messages policies: %', SQLERRM;
END;
$$;
