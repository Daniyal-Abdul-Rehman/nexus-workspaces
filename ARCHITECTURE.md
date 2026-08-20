# Nexus Workspaces - Architecture Documentation

## Table of Contents

- [Entity Relationship Overview](#entity-relationship-overview)
- [Organization and Project Authorization Model](#organization-and-project-authorization-model)
- [Why Specific Logic Belongs in RLS vs Database Functions vs Edge Functions](#why-specific-logic-belongs-in-rls-vs-database-functions-vs-edge-functions)
- [How Confidential-Project Access is Centralized](#how-confidential-project-access-is-centralized)
- [Invitation Strategy](#invitation-strategy)
- [Webhook Strategy](#webhook-strategy)
- [Concurrency Strategy](#concurrency-strategy)
- [Deletion and Retention Choices](#deletion-and-retention-choices)
- [Realtime Authorization Design](#realtime-authorization-design)
- [Storage Authorization Design](#storage-authorization-design)
- [Known Trade-offs and Likely Next Refactors](#known-trade-offs-and-likely-next-refactors)
- [Task Revision History Extension Design](#task-revision-history-extension-design)

## Entity Relationship Overview

### Core Entities

```
profiles (1) ----< (1) organisation_memberships (many) >---- (1) organisations
profiles (1) ----< (1) project_memberships (many) >---- (1) projects ----< (1) organisations
projects (1) ----< (many) tasks ----< (many) comments
projects (1) ----< (many) comments (project-level)
organisations (1) ----< (many) invitations
organisations (1) ----< (many) audit_events
projects (1) ----< (many) audit_events
organisations (1) ----< (many) webhook_events (via source mapping)
```

### Key Relationships

- **profiles** ↔ **auth.users**: 1:1 mapping via foreign key, isolates auth schema from application data
- **organisations** ↔ **organisation_memberships**: 1:N hierarchical ownership with single owner constraint
- **projects** ↔ **organisations**: N:1 ownership with cascading deletion
- **projects** ↔ **project_memberships**: N:M explicit access control independent of org membership
- **tasks** ↔ **projects**: N:1 ownership with cascading deletion
- **comments** ↔ **projects/tasks**: N:1 ownership with optional task association
- **invitations** ↔ **organisations**: N:1 ownership with token-based acceptance
- **audit_events**: Append-only log with optional organisation/project context
- **webhook_events**: Idempotency records for external system integration

### Design Rationale

1. **Separation of Concerns**: Profiles table isolates auth.users from application logic, preventing direct client access to auth schema
2. **Hierarchical Ownership**: Organisations own projects, projects own tasks/comments - clear data boundaries
3. **Explicit Access Control**: Both organisation and project memberships provide layered authorization
4. **Audit Trail**: Comprehensive audit events track all important state changes
5. **Idempotency**: Webhook events ensure external system integration reliability

## Organization and Project Authorization Model

### Organization Roles

| Role | Permissions | Rationale |
|------|-------------|-----------|
| **Owner** | Full control, can transfer ownership, cannot be removed by others | Single point of accountability, prevents privilege escalation |
| **Admin** | Can manage members/projects, cannot modify owner | Operational control without ownership rights |
| **Member** | Can access assigned projects, can enumerate org members | Standard employee access |
| **Guest** | Limited to explicitly assigned projects, cannot enumerate members | External collaborator access with minimal visibility |

### Project Roles

| Role | Permissions | Rationale |
|------|-------------|-----------|
| **Manager** | Full project control, can manage membership | Project-level administration |
| **Contributor** | Can create/edit tasks and comments, upload files | Active project participant |
| **Viewer** | Read-only access to project data | Observation-only access |

### Access Control Matrix

```
                    | Org | Org | Org | Proj| Proj| Proj| Task| Task| Comm| Comm| File| File
Operation           | Own | Adm | Mem | Mgr | Ctr | Vwr | Cre| Edt| Cre| Edt | Upl | Del
--------------------|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----
View Org            | ✓   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
View Project        | ✓   | ✓   | ✗   | ✓   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Create Project      | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Edit Project        | ✓   | ✓   | ✗   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Delete Project      | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Manage Proj Members | ✓   | ✓   | ✗   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
View Tasks          | ✓   | ✓   | ✗   | ✓   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Create Tasks        | ✓   | ✓   | ✗   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Edit Tasks          | ✓   | ✓   | ✗   | ✓   | *   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Delete Tasks        | ✓   | ✓   | ✗   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
View Comments       | ✓   | ✓   | ✗   | ✓   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Create Comments     | ✓   | ✓   | ✗   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Edit Comments       | ✓   | ✓   | ✗   | ✓   | *   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Delete Comments     | ✓   | ✓   | ✗   | ✓   | *   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Upload Files        | ✓   | ✓   | ✗   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Download Files      | ✓   | ✓   | ✗   | ✓   | ✓   | ✓   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗
Delete Files        | ✓   | ✓   | ✗   | ✓   | *   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗   | ✗

* = Only for own tasks/comments/files
```

### Confidential Project Modifications

For confidential projects, the access control matrix changes:

- **Admin** loses automatic project access (row 3-14: Admin role ✗ for confidential projects)
- **Admin** must be explicitly added to project_memberships for access
- **Owner** retains automatic access regardless of project type
- **Project members** access unchanged

This modification is centralized in the `has_project_access()` and `can_manage_project()` functions.

## Why Specific Logic Belongs in RLS vs Database Functions vs Edge Functions

### Row Level Security (RLS)

**Used for:**
- Data visibility and access control at the row level
- Tenant isolation enforcement
- CRUD operation authorization
- Protection against direct client manipulation

**Why:**
- Database-level enforcement, bypassable only by service role
- Automatic application to all queries via client libraries
- Centralized, declarative security model
- Performance: evaluated at query planning time
- Prevents unauthorized access even if client is compromised

**Examples:**
- Organisation membership visibility (guests see only own membership)
- Project access control (confidential vs normal projects)
- Task/comment CRUD authorization
- Storage object access control

### Database Functions

**Used for:**
- Complex, multi-step operations requiring atomicity
- Security-sensitive operations that need privilege elevation
- Operations requiring validation beyond simple RLS
- Centralized business logic reused across policies

**Why:**
- Transactional consistency (all-or-nothing operations)
- SECURITY DEFINER allows controlled privilege elevation
- Can perform validation and audit logging atomically
- Reusable across different contexts
- Performance: single round-trip for complex operations

**Examples:**
- `accept_invitation()`: Token validation, membership creation, audit logging
- `transition_task_status()`: Version checking, authorization, audit logging
- `has_project_access()`: Centralized access control logic
- `can_manage_project()`: Centralized management authorization

### Edge Functions

**Used for:**
- External system integration (webhooks)
- Cryptographic operations (token generation)
- Email sending and external notifications
- Operations requiring Node.js/Deno runtime
- Validation that needs to happen before database operations

**Why:**
- Can access external APIs and services
- Provides additional security boundary
- Can perform operations not available in SQL
- Can implement rate limiting and abuse prevention
- Separates concerns between database and external integration

**Examples:**
- `invite-member`: Token generation, email integration (in production)
- `external-webhook`: Signature verification, external system processing

### Decision Criteria

| Factor | RLS | Database Functions | Edge Functions |
|--------|-----|-------------------|----------------|
| Tenant isolation | ✓ | - | - |
| Complex multi-step operations | - | ✓ | - |
| External API calls | - | - | ✓ |
| Cryptographic operations | - | - | ✓ |
| Simple CRUD authorization | ✓ | - | - |
| Atomic transaction requirements | - | ✓ | - |
| Email/notification sending | - | - | ✓ |
| Performance (single query) | ✓ | ✓ | - |
| Bypass RLS (intentional) | - | SECURITY DEFINER | Service role |

## How Confidential-Project Access is Centralized

The confidential project access logic is centralized in two key functions:

### `has_project_access(project_id, user_id, access_level)`

This function determines read access to projects and is used by:
- Project RLS SELECT policies
- Task RLS policies (inherit project access)
- Comment RLS policies (inherit project access)
- Storage RLS policies (file access)
- Realtime channel authorization (planned)

**Confidential logic:**
```sql
IF access_mode = 'confidential' THEN
    IF org_role = 'owner' THEN
        RETURN TRUE;
    END IF;
    IF project_role IS NOT NULL THEN
        RETURN TRUE;
    END IF;
    RETURN FALSE; -- Admins excluded
END IF;
```

### `can_manage_project(project_id, user_id)`

This function determines management rights and is used by:
- Project RLS UPDATE/DELETE policies
- Project membership RLS policies
- Task/comment management policies

**Confidential logic:**
```sql
IF access_mode = 'confidential' THEN
    IF org_role = 'owner' THEN
        RETURN TRUE;
    END IF;
    IF project_role = 'manager' THEN
        RETURN TRUE;
    END IF;
    RETURN FALSE; -- Admins excluded
END IF;
```

### Centralization Benefits

1. **Single source of truth**: Access logic defined once, reused everywhere
2. **Easy modification**: Changing access rules requires updating only these functions
3. **Consistency**: All authorization paths use the same logic
4. **Testing**: Easier to test and verify access control
5. **Performance**: Function inlining and query optimization

### Additional Centralization Points

- **Storage policies**: Use the same `has_project_access()` function
- **Realtime authorization**: Will use `has_project_access()` for channel subscriptions
- **Trigger validation**: `validate_access_mode_change()` prevents invalid transitions
- **Audit logging**: `log_access_mode_change()` tracks all access mode changes

This design means that when the access model changes (like the confidential project requirement), only the helper functions need modification, not every individual policy.

## Invitation Strategy

### Security Design

1. **Token Generation**: Cryptographically secure UUIDs generated in Edge Functions
2. **Token Storage**: Only SHA-256 digests stored in database, raw tokens never persisted
3. **Token Validation**: Tokens hashed client-side and compared against stored digests
4. **Expiry**: 7-day expiry window enforced at acceptance time
5. **One-time Use**: Accepted invitations marked to prevent reuse
6. **Email Binding**: Tokens can only be accepted by matching email addresses
7. **Replay Prevention**: Row-level locking prevents concurrent double acceptance

### Workflow

```
1. Owner/Admin calls invite-member Edge Function
2. Edge Function verifies caller authorization
3. Edge Function generates secure token
4. Edge Function stores token digest (not raw token)
5. Edge Function sends email with token (production) or returns URL (dev)
6. Recipient clicks link/token
7. Frontend calls accept_invitation() with token
8. Function validates token, expiry, email match
9. Function creates/updates membership atomically
10. Function marks invitation accepted
11. Function writes audit event
12. Function returns success
```

### Concurrency Handling

The `accept_invitation()` function uses `FOR UPDATE` locking:

```sql
SELECT * FROM invitations
WHERE token_digest = ...
FOR UPDATE; -- Locks row for this transaction
```

This prevents:
- Two concurrent requests accepting the same invitation
- Race conditions in membership creation
- Duplicate audit events

### Idempotency

The `invite-member` Edge Function checks for existing pending invitations:

```sql
SELECT * FROM invitations
WHERE organisation_id = ? AND email = ?
AND accepted_at IS NULL AND expires_at > NOW()
```

If found, returns existing invitation instead of creating duplicate.

## Webhook Strategy

### Security Design

1. **Signature Verification**: HMAC-SHA256 signature verification using shared secret
2. **Timestamp Validation**: 5-minute window to prevent replay attacks
3. **Timing-Safe Comparison**: Prevents timing attacks on signature verification
4. **Raw Body Verification**: Signature computed on raw body, not parsed JSON
5. **Idempotency Keys**: Event IDs prevent duplicate processing
6. **Event Tracking**: Database records all webhook delivery attempts

### Workflow

```
1. External system sends webhook with signature
2. Edge Function verifies required headers
3. Edge Function reads raw request body
4. Edge Function validates timestamp (5-minute window)
5. Edge Function verifies HMAC signature
6. Edge Function checks for existing event (idempotency)
7. Edge Function processes event payload
8. Edge Function updates event status
9. Edge Function returns appropriate response
```

### Replay Protection

Multiple layers of replay protection:

1. **Timestamp window**: Rejects events outside 5-minute window
2. **Event ID tracking**: Database prevents duplicate event_id processing
3. **Signature verification**: Prevents token/signature reuse
4. **Status tracking**: Events marked as processed/failed to prevent reprocessing

### Idempotency

The webhook event table ensures:

```sql
UNIQUE constraint on event_id
Status tracking (pending, processed, failed)
```

Duplicate deliveries return existing event status without reprocessing.

## Concurrency Strategy

### Optimistic Concurrency for Tasks

Tasks use a version column for optimistic concurrency control:

```sql
version INTEGER NOT NULL DEFAULT 1
```

### Workflow

```
1. Client reads task with version N
2. Client modifies task
3. Client calls transition_task_status(task_id, new_status, version=N)
4. Function checks if current version == N
5. If match: update task, increment version to N+1
6. If mismatch: reject update, return error
7. Audit event records version transition
```

### Benefits

- No database locks for read operations
- Detects concurrent modifications
- Provides clear error messages to clients
- Maintains audit trail of all changes

### Implementation

The `transition_task_status()` function enforces:

```sql
IF v_task.version != p_expected_version THEN
    RAISE EXCEPTION 'Task version mismatch';
END IF;

UPDATE tasks
SET status = p_new_status,
    version = version + 1
WHERE id = p_task_id
AND version = p_expected_version; -- Double-check in UPDATE
```

### Other Concurrency Handling

- **Invitations**: Row-level locking with `FOR UPDATE`
- **Webhooks**: Database unique constraints on event_id
- **Memberships**: Unique constraints prevent duplicate memberships
- **Projects**: Trigger validation prevents invalid access_mode changes

## Deletion and Retention Choices

### Cascade Behavior

| Relationship | ON DELETE Behavior | Rationale |
|--------------|-------------------|-----------|
| profiles → auth.users | CASCADE | Profile tied to auth account, should not exist without user |
| organisations → organisation_memberships | CASCADE | Memberships meaningless without organisation |
| projects → tasks | CASCADE | Tasks cannot exist without project |
| projects → comments | CASCADE | Comments cannot exist without project context |
| projects → project_memberships | CASCADE | Project memberships meaningless without project |
| tasks → comments (task-level) | CASCADE | Task-specific comments tied to task |
| invitations → organisations | CASCADE | Invitations meaningless without organisation |
| audit_events → organisations | CASCADE | Org-specific audit events tied to organisation |
| audit_events → projects | CASCADE | Project-specific audit events tied to project |

### Soft Deletion vs Hard Deletion

**Hard Deletion Used For:**
- End-user content (tasks, comments) when explicitly deleted
- Project structure when archived/deleted
- Organisation when closed

**Soft Deletion (Status) Used For:**
- Projects (status: active/archived)
- Organisations (status: active/suspended/archived)
- Tasks (status: cancelled instead of deletion)

**Rationale:**
- Active data uses status fields for better query performance
- Hard deletion for cleanup when data is no longer needed
- Audit trail preserved regardless of deletion

### Audit Trail Retention

**Design Choice:**
- Audit events are append-only with no deletion mechanism
- Organisation deletion cascades to audit events (reasonable cleanup)
- No automatic expiry of audit events

**Rationale:**
- Security and compliance requirements
- Forensic analysis capabilities
- Simple retention model (indefinite)

**Production Consideration:**
- Add archival mechanism for old audit events
- Implement retention policies based on compliance requirements
- Consider partitioning by date for performance

### Account Deletion Impact

When a user account is deleted (auth.users):

1. **Profile**: Deleted via CASCADE
2. **Organisation memberships**: Deleted via CASCADE
3. **Project memberships**: Deleted via CASCADE
4. **Authored content**: 
   - Tasks: `created_by` set to NULL (via ON DELETE SET NULL)
   - Comments: Author preserved for attribution (RESTRICT prevents deletion)
   - Files: Uploader preserved (RESTRICT prevents deletion)
5. **Audit events**: Actor ID preserved (SET NULL)

**Rationale:**
- Preserve content attribution even after user deletion
- Clean up membership and access control
- Maintain audit trail for security
- Allow reassignment of important content

## Realtime Authorization Design

### Channel Naming Convention

```
project:{project_id}
```

Example: `project:20000000-0000-0000-0000-000000000001`

### Authorization Strategy

Realtime authorization uses the `can_subscribe_to_realtime_project()` function, which internally uses the same `has_project_access()` logic as RLS policies:

```sql
CREATE OR REPLACE FUNCTION can_subscribe_to_realtime_project(
    p_channel_name TEXT,
    p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN AS $$
DECLARE
    v_project_id UUID;
BEGIN
    -- Extract project_id from channel name
    IF p_channel_name LIKE 'project:%' THEN
        v_project_id := split_part(p_channel_name, ':', 2)::UUID;
    ELSEIF p_channel_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        v_project_id := p_channel_name::UUID;
    ELSE
        RETURN FALSE; -- Invalid channel format
    END IF;

    IF v_project_id IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Use the same project access logic as RLS policies
    RETURN public.has_project_access(v_project_id, p_user_id, 'read');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
```

### Implementation Options

**Option 1: Broadcast (Preferred)**
- Edge Functions or database triggers publish to channels
- Authorization checked before publishing
- Subscribers authorized via RLS-style channel policies
- More control over payload content

**Option 2: Postgres Changes**
- Database triggers automatically publish changes
- RLS policies filter what subscribers receive
- Less control over payload format
- Automatic but potentially leaky

**Chosen Approach: Broadcast**

Rationale:
- Greater control over authorization
- Can filter sensitive columns from payloads
- Explicit authorization checks
- Better security boundary

### Channel Security

1. **Channel Name Obfuscation**: Not needed, security via authorization
2. **JWT Validation**: Supabase validates JWT before connection
3. **Project Access Check**: `can_subscribe_to_realtime_project()` called for each subscription
4. **Payload Filtering**: Sensitive columns excluded from broadcasts
5. **Consistent Authorization**: Uses same `has_project_access()` function as RLS policies
5. **Connection Lifecycle**: Access rechecked on JWT refresh

### Project Access Changes

When project access changes:
1. Database triggers notify application
2. Application invalidates affected Realtime connections
3. Clients reconnect and re-authorize
4. New access rules applied

### JWT Refresh Impact

- Long-lived connections may have stale authorization
- Implementation should re-check access periodically
- Or use short-lived connection lifetimes with reconnection

## Storage Authorization Design

### Bucket Configuration

- **Bucket Name**: `project-files`
- **Public**: false (private bucket)
- **File Size Limit**: 10MB
- **Allowed MIME Types**: Images, PDFs, text, documents

### Path Convention

```
{organisation_id}/{project_id}/{user_id}/{filename}
```

Example: `10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000001/document.pdf`

### Authorization Strategy

Storage RLS policies extract project_id from path and use `has_project_access()`:

```sql
-- Extract project_id from path
split_part(name, '/', 2)::UUID

-- Check access using same function as database
has_project_access(project_id, auth.uid())
```

### Policy Breakdown

**SELECT (Download/List)**
- Users with project access can download
- Uses `has_project_access()` for authorization
- Confidential project rules apply

**INSERT (Upload)**
- Contributors, managers, owners, admins can upload
- User must match user_id in path
- Project access verified

**UPDATE (Move/Rename)**
- Prevents changing project_id in path
- Maintains project context
- Same authorization as SELECT

**DELETE**
- Uploader can delete own files
- Managers can delete any files
- Owners/admins can delete any files
- Confidential project rules apply

### Security Considerations

1. **Path Manipulation Prevention**: Project_id locked in UPDATE policy
2. **No Public Access**: Private bucket prevents anonymous access
3. **MIME Type Validation**: Server-side validation of file types
4. **Size Limits**: 10MB limit prevents abuse
5. **User Context**: User_id in path prevents upload forgery

### Signed URLs (Not Implemented)

If signed URLs were used:
- Lifetime: 15 minutes maximum
- Creation: Only via Edge Functions with proper authorization
- Scope: Single file, single operation
- Revocation: Database-triggered URL invalidation

## Known Trade-offs and Likely Next Refactors

### Current Trade-offs

1. **UUID vs Auto-increment IDs**
   - **Choice**: UUIDs everywhere
   - **Trade-off**: Larger indexes, slower joins vs global uniqueness
   - **Next refactor**: Consider auto-increment for large tables (tasks, comments)

2. **ENUM vs CHECK Constraints**
   - **Choice**: CHECK constraints for roles
   - **Trade-off**: Less type safety vs easier migration
   - **Next refactor**: Consider ENUM for stable roles (owner, admin, member)

3. **Separate Audit Tables**
   - **Choice**: Single audit_events table
   - **Trade-off**: Large table vs simpler queries
   - **Next refactor**: Partition by date or organisation for performance

4. **Realtime Implementation**
   - **Choice**: Designed but not fully implemented
   - **Trade-off**: Incomplete vs assessment scope
   - **Next refactor**: Complete Broadcast implementation with authorization

5. **Email Integration**
   - **Choice**: Development URLs instead of real email
   - **Trade-off**: Not production-ready vs assessment constraints
   - **Next refactor**: Integrate SendGrid/AWS SES for production

6. **Test Data Volume**
   - **Choice**: 100K tasks, 500K comments in seed data
   - **Trade-off**: Long migration time vs realistic performance testing
   - **Next refactor**: Separate performance test migration

### Performance Considerations

1. **RLS Policy Overhead**
   - **Impact**: Each query evaluates RLS predicates
   - **Mitigation**: Indexed columns used in RLS, helper functions optimized
   - **Monitoring**: Track query plans with RLS enabled

2. **Large Table Scans**
   - **Risk**: Full table scans on tasks/comments at scale
   - **Mitigation**: Partial indexes, covering indexes, proper query design
   - **Next refactor**: Partition large tables by date or project

3. **Foreign Key Cascades**
   - **Risk**: Long-running transactions on cascading deletes
   - **Mitigation**: Soft deletes where possible, batch deletes
   - **Next refactor**: Async cleanup for large cascades

### Security Considerations

1. **Service Role Usage**
   - **Current**: Edge Functions use service role
   - **Risk**: If Edge Function compromised, full database access
   - **Mitigation**: Strict input validation, minimal function scope
   - **Next refactor**: Row-level security even for service role where possible

2. **Token Storage**
   - **Current**: SHA-256 digests in database
   - **Risk**: Database compromise exposes token digests
   - **Mitigation**: Tokens expire in 7 days, require email match
   - **Next refactor**: Consider key management service for tokens

3. **JWT Lifetime**
   - **Current**: Supabase default JWT lifetime
   - **Risk**: Long-lived tokens with stale authorization
   - **Mitigation**: Re-check critical operations, short-lived sessions
   - **Next refactor**: Implement token refresh with re-authorization

### Scalability Considerations

1. **Single Database**
   - **Current**: Single PostgreSQL instance
   - **Limit**: Will hit vertical scaling limits
   - **Next refactor**: Read replicas, connection pooling, eventual sharding

2. **Storage Backend**
   - **Current**: Supabase Storage (S3-compatible)
   - **Limit**: Single bucket, potential hot spots
   - **Next refactor**: Multiple buckets by organisation or date

3. **Realtime Connections**
   - **Current**: Supabase Realtime
   - **Limit**: Connection limits per project
   - **Next refactor**: Connection pooling, message batching

### Maintainability Considerations

1. **Migration Complexity**
   - **Current**: Large migrations with multiple concerns
   - **Risk**: Migration failures, hard to rollback
   - **Next refactor**: Split migrations by feature, add rollback scripts

2. **Function Proliferation**
   - **Current**: Many helper functions for RLS
   - **Risk**: Hard to understand, difficult to modify
   - **Next refactor**: Consolidate related functions, add documentation

3. **Test Coverage**
   - **Current**: DO block tests, not full pgTAP
   - **Risk**: Incomplete test coverage, hard to run
   - **Next refactor**: Full pgTAP integration, client-level tests

## Task Revision History Extension Design

### Requirements

- Immutable revision history for task title, description, and status
- Users cannot rewrite prior revisions
- History must be queryable for audit and compliance
- Current task state remains in main table for performance

### Proposed Schema

```sql
CREATE TABLE public.task_revisions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    task_id UUID NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
    revision_number INTEGER NOT NULL,
    title TEXT,
    description TEXT,
    status TEXT,
    revised_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    revised_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revision_metadata JSONB,
    
    UNIQUE(task_id, revision_number)
);

CREATE INDEX idx_task_revisions_task ON public.task_revisions(task_id, revision_number);
CREATE INDEX idx_task_revisions_revised_at ON public.task_revisions(revised_at DESC);
```

### Implementation Strategy

#### Option 1: Trigger-Based Auto-Archiving

```sql
CREATE OR REPLACE FUNCTION archive_task_revision()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.title IS DISTINCT FROM NEW.title OR
       OLD.description IS DISTINCT FROM NEW.description OR
       OLD.status IS DISTINCT FROM NEW.status THEN
       
        INSERT INTO public.task_revisions (
            task_id,
            revision_number,
            title,
            description,
            status,
            revised_by,
            revision_metadata
        ) VALUES (
            NEW.id,
            (SELECT COALESCE(MAX(revision_number), 0) + 1 
             FROM public.task_revisions 
             WHERE task_id = NEW.id),
            OLD.title,
            OLD.description,
            OLD.status,
            auth.uid(),
            jsonb_build_object(
                'previous_version', OLD.version,
                'new_version', NEW.version
            )
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_archive_task_revision
    BEFORE UPDATE ON public.tasks
    FOR EACH ROW
    EXECUTE FUNCTION public.archive_task_revision();
```

#### Option 2: Application-Controlled Revisioning

Require explicit revision creation through a function:

```sql
CREATE OR REPLACE FUNCTION create_task_revision(
    p_task_id UUID,
    p_title TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_revision_id UUID;
    v_current_task RECORD;
BEGIN
    -- Get current task state
    SELECT * INTO v_current_task
    FROM public.tasks
    WHERE id = p_task_id;
    
    -- Create revision
    INSERT INTO public.task_revisions (
        task_id,
        revision_number,
        title,
        description,
        status,
        revised_by
    ) VALUES (
        p_task_id,
        (SELECT COALESCE(MAX(revision_number), 0) + 1 
         FROM public.task_revisions 
         WHERE task_id = p_task_id),
        COALESCE(p_title, v_current_task.title),
        COALESCE(p_description, v_current_task.description),
        COALESCE(p_status, v_current_task.status),
        auth.uid()
    ) RETURNING id INTO v_revision_id;
    
    RETURN v_revision_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Authorization

- **Read Revision History**: Users who can view the task can view its history
- **Create Revisions**: Only when authorized to modify the task
- **Delete Revisions**: Never (immutable by design)

```sql
-- RLS for task_revisions
ALTER TABLE public.task_revisions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users with task access can read revisions"
    ON public.task_revisions FOR SELECT
    USING (has_project_access(
        (SELECT project_id FROM public.tasks WHERE id = task_id),
        auth.uid()
    ));

-- No INSERT/UPDATE/DELETE policies for clients
-- Revisions created only by triggers or privileged functions
```

### Query Patterns

```sql
-- Get revision history for a task
SELECT * FROM public.task_revisions
WHERE task_id = $1
ORDER BY revision_number;

-- Get specific revision
SELECT * FROM public.task_revisions
WHERE task_id = $1 AND revision_number = $2;

-- Compare revisions
SELECT 
    r1.revision_number as from_revision,
    r2.revision_number as to_revision,
    r1.title as old_title,
    r2.title as new_title,
    r1.description as old_description,
    r2.description as new_description
FROM public.task_revisions r1
JOIN public.task_revisions r2 ON r1.task_id = r2.task_id
WHERE r1.task_id = $1
AND r1.revision_number = $2
AND r2.revision_number = $3;
```

### Trade-offs

**Trigger-Based:**
- ✓ Automatic, no application changes needed
- ✓ Guaranteed history for all changes
- ✗ Cannot be selective about what to archive
- ✗ Harder to debug unexpected revisions

**Application-Controlled:**
- ✓ Selective revision creation
- ✓ Easier to understand and debug
- ✗ Requires application changes
- ✗ Risk of missing revisions if application forgets

**Recommendation**: Trigger-based for data integrity, with application function for explicit revision snapshots when needed.

### Performance Considerations

- **Impact**: Every task UPDATE creates a revision row
- **Mitigation**: Consider archiving old revisions to cold storage
- **Indexing**: Proper indexes on task_id and revision_number
- **Partitioning**: Consider partitioning by date for large history tables

This design provides immutable, queryable revision history while maintaining performance for current task operations.