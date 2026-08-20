# Nexus Workspaces - Security Documentation

## Table of Contents

- [Threat Model](#threat-model)
- [Attack Vectors and Mitigations](#attack-vectors-and-mitigations)
- [Key and Secret Handling](#key-and-secret-handling)
- [RLS Policy Security Analysis](#rls-policy-security-analysis)
- [Edge Function Security Boundaries](#edge-function-security-boundaries)
- [Authentication and Authorization](#authentication-and-authorization)
- [Known Residual Risks](#known-residual-risks)
- [Security Best Practices](#security-best-practices)

## Threat Model

### Assumptions

1. **Untrusted Client**: Frontend applications are considered untrusted
2. **Direct API Access**: Users may call Supabase APIs directly with valid credentials
3. **Credential Exposure**: JWT tokens may be exposed to end users
4. **Malicious Users**: Some users may actively attempt to bypass security controls
5. **Database Compromise**: Database may be compromised (defense in depth)
6. **Insider Threats**: Privileged users may abuse their access

### Security Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                       CLIENT LAYER                            │
│  (Untrusted: can be modified, manipulated, or bypassed)      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    SUPABASE API LAYER                         │
│  (JWT validation, RLS enforcement, API key checks)            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   DATABASE LAYER                             │
│  (RLS policies, constraints, triggers, functions)            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  STORAGE LAYER                                │
│  (Storage RLS, path validation, MIME type checking)           │
└─────────────────────────────────────────────────────────────┘
```

### Threat Categories

#### 1. Cross-Tenant Data Access
**Threat**: User A accessing User B's organisation data
**Impact**: High - data breach, privacy violation
**Likelihood**: Medium - UUID enumeration possible

#### 2. Privilege Escalation
**Threat**: User elevating their role without authorization
**Impact**: High - unauthorized control over resources
**Likelihood**: Medium - if RLS policies are flawed

#### 3. Data Injection/Manipulation
**Threat**: Malicious data inserted to exploit application logic
**Impact**: Medium - application behavior manipulation
**Likelihood**: High - if input validation is weak

#### 4. Replay Attacks
**Threat**: Reusing valid requests/tokens to cause duplicate actions
**Impact**: Medium - duplicate operations, state inconsistency
**Likelihood**: Medium - if idempotency is weak

#### 5. Man-in-the-Middle Attacks
**Threat**: Intercepting/modifying communications
**Impact**: High - credential theft, data modification
**Likelihood**: Low - HTTPS required

#### 6. SQL Injection
**Threat**: Malicious SQL executed via parameter manipulation
**Impact**: Critical - full database compromise
**Likelihood**: Low - parameterized queries used

#### 7. Storage Path Traversal
**Threat**: Accessing files outside authorized scope
**Impact**: High - unauthorized file access
**Likelihood**: Medium - if path validation is weak

#### 8. Webhook Signature Forgery
**Threat**: Forging webhook signatures to trigger unauthorized actions
**Impact**: High - unauthorized business operations
**Likelihood**: Low - signature verification implemented

## Attack Vectors and Mitigations

### Cross-Tenant Data Access

**Attack Vector 1: UUID Enumeration**
- **Description**: Attacker guesses organisation/project UUIDs
- **Mitigation**: RLS policies prevent cross-tenant access regardless of UUID knowledge
- **Implementation**: All tenant-scoped tables use RLS with organization/project membership checks

**Attack Vector 2: Direct API Calls**
- **Description**: Attacker uses Supabase client directly with valid JWT
- **Mitigation**: RLS enforced at database level, cannot be bypassed by client
- **Implementation**: RLS enabled on all tenant tables, no client-side bypass

**Attack Vector 3: Membership Insertion**
- **Description**: Attacker inserts themselves into organisation_memberships
- **Mitigation**: No INSERT policy for organisation_memberships for regular users
- **Implementation**: Membership creation only through invitations or privileged functions

### Privilege Escalation

**Attack Vector 1: Role Manipulation**
- **Description**: Attacker UPDATEs their role in organisation_memberships
- **Mitigation**: RLS UPDATE policy prevents role changes by non-admins
- **Implementation**: Admins cannot modify owner role; owners cannot be removed

**Attack Vector 2: Project Membership Elevation**
- **Description**: Guest attempts to become project manager
- **Mitigation**: Database trigger prevents guest manager promotion
- **Implementation**: `prevent_guest_manager_promotion()` trigger

**Attack Vector 3: Client-Supplied Roles**
- **Description**: Attacker supplies role in API calls
- **Mitigation**: Roles never trusted from client, always from database
- **Implementation**: All authorization checks use database role fields

### Data Injection/Manipulation

**Attack Vector 1: Malicious Task Content**
- **Description**: Attacker inserts XSS or malicious content in tasks
- **Mitigation**: Input validation and sanitization at application layer
- **Implementation**: Frontend validation + database constraints

**Attack Vector 2: Status Manipulation**
- **Description**: Attacker attempts invalid task status transitions
- **Mitigation**: CHECK constraint on status field
- **Implementation**: `CHECK (status IN ('todo', 'in_progress', 'done', 'cancelled'))`

**Attack Vector 3: Email Spoofing in Invitations**
- **Description**: Attacker sends invitation to unauthorized email
- **Mitigation**: Authorization check before invitation creation
- **Implementation**: Only owners/admins can create invitations

### Replay Attacks

**Attack Vector 1: Invitation Replay**
- **Description**: Attacker reuses invitation token
- **Mitigation**: One-time use with row locking and accepted_at check
- **Implementation**: `FOR UPDATE` lock in `accept_invitation()`

**Attack Vector 2: Webhook Replay**
- **Description**: Attacker replays valid webhook event
- **Mitigation**: Event ID tracking with unique constraint
- **Implementation**: `webhook_events` table with `UNIQUE(event_id)`

**Attack Vector 3: Task Update Replay**
- **Description**: Attacker reuses old task version
- **Mitigation**: Optimistic concurrency with version checking
- **Implementation**: `transition_task_status()` version validation

### Storage Path Traversal

**Attack Vector 1: Path Manipulation**
- **Description**: Attacker modifies storage paths to access other projects
- **Mitigation**: Path validation and project_id locking in UPDATE policy
- **Implementation**: Storage RLS policies extract and validate project_id

**Attack Vector 2: Directory Traversal**
- **Description**: Attacker uses `../` in paths
- **Mitigation**: Path sanitization and validation
- **Implementation**: UUID-based paths prevent directory traversal

### Webhook Signature Forgery

**Attack Vector 1: Signature Bypass**
- **Description**: Attacker omits or forges webhook signature
- **Mitigation**: Required signature header with HMAC verification
- **Implementation**: Timing-safe signature comparison in Edge Function

**Attack Vector 2: Timestamp Manipulation**
- **Description**: Attacker uses old or future timestamps
- **Mitigation**: 5-minute timestamp window validation
- **Implementation**: Timestamp check before signature verification

## Key and Secret Handling

### Supabase Keys

#### Anon Key (Public)
- **Usage**: Client-side Supabase client initialization
- **Exposure**: Acceptable - designed for public use
- **Capabilities**: Limited by RLS policies
- **Storage**: Environment variables, committed to repo (safe)

#### Service Role Key (Secret)
- **Usage**: Edge Functions, admin operations
- **Exposure**: Never - must be kept secret
- **Capabilities**: Bypasses RLS, full database access
- **Storage**: Environment variables, never committed to repo
- **Rotation**: Regular rotation recommended

### Webhook Secret
- **Usage**: HMAC signature verification for webhooks
- **Exposure**: Never - must be kept secret
- **Capabilities**: Allows webhook signature verification
- **Storage**: Environment variables, never committed to repo
- **Rotation**: Coordinate with webhook provider

### Invitation Tokens
- **Usage**: One-time invitation acceptance
- **Exposure**: Transient - sent via email, short-lived
- **Capabilities**: Allows organisation membership creation
- **Storage**: Only SHA-256 digests stored in database
- **Lifetime**: 7 days maximum

### JWT Tokens
- **Usage**: User authentication, session management
- **Exposure**: Client-side storage (localStorage, cookies)
- **Capabilities**: Represents user identity, scoped by RLS
- **Lifetime**: Configurable (default 1 hour)
- **Refresh**: Automatic refresh via Supabase Auth

### Key Management Best Practices

1. **Environment Variables**: All secrets stored in environment variables
2. **No Commits**: Never commit secrets to version control
3. **Least Privilege**: Use most restrictive key for each use case
4. **Regular Rotation**: Rotate keys periodically and on compromise
5. **Access Logging**: Monitor key usage for suspicious activity
6. **Secure Storage**: Use secret management services in production

### Development vs Production

**Development:**
- Local Supabase stack with auto-generated keys
- Local environment file for testing
- No real secrets exposed

**Production:**
- Separate keys for development and production
- Secure secret management (AWS Secrets Manager, etc.)
- Key rotation policies
- Audit logging for key usage

## RLS Policy Security Analysis

### Policy Security Principles

1. **Defense in Depth**: Multiple layers of security checks
2. **Default Deny**: No access unless explicitly granted
3. **Principle of Least Privilege**: Minimum required access
4. **Tenant Isolation**: Strict separation between organisations
5. **Input Validation**: Never trust client-supplied identifiers

### Critical Policy Analysis

#### Organisation Memberships RLS

**Security Concern: Guest Enumeration**
- **Policy**: Guests can only see their own membership
- **Implementation**: Separate policy for guests with `user_id = auth.uid()`
- **Risk Mitigation**: Prevents guests from enumerating org members

**Security Concern: Owner Protection**
- **Policy**: Admins cannot modify owner role
- **Implementation**: Complex USING/WITH CHECK clause
- **Risk Mitigation**: Prevents privilege escalation and hostile takeovers

#### Projects RLS

**Security Concern: Confidential Project Access**
- **Policy**: Uses `has_project_access()` function
- **Implementation**: Function checks access_mode and roles
- **Risk Mitigation**: Centralized logic prevents bypass

**Security Concern: Project Creation**
- **Policy**: Only owners/admins can create projects
- **Implementation**: EXISTS subquery for role check
- **Risk Mitigation**: Prevents unauthorized project creation

#### Tasks RLS

**Security Concern: Task Reassignment**
- **Policy**: WITH CHECK prevents project_id changes
- **Implementation**: `has_project_access(NEW.project_id, auth.uid())`
- **Risk Mitigation**: Prevents moving tasks between unauthorized projects

**Security Concern: Update Authorization**
- **Policy**: Creators, assignees, and managers can update
- **Implementation**: Multiple conditions with OR logic
- **Risk Mitigation**: Balanced security with usability

#### Storage RLS

**Security Concern: Path Manipulation**
- **Policy**: UPDATE policy locks project_id
- **Implementation**: `split_part(name, '/', 2)::UUID = split_part(OLD.name, '/', 2)::UUID`
- **Risk Mitigation**: Prevents cross-project file moves

**Security Concern: Upload Authorization**
- **Policy**: User must match user_id in path
- **Implementation**: `split_part(name, '/', 3)::TEXT = auth.uid()::TEXT`
- **Risk Mitigation**: Prevents upload forgery

### RLS Performance vs Security

**Security Considerations:**
- Complex RLS predicates may impact query performance
- Function calls in RLS add overhead
- Index usage critical for RLS performance

**Mitigations:**
- Strategic indexes on RLS filter columns
- Optimized helper functions with minimal logic
- Partial indexes for common query patterns
- Query plan analysis for RLS-heavy queries

### RLS Testing Strategy

**Unit Testing:**
- Test each policy in isolation
- Test USING vs WITH CHECK behavior
- Test role-based access matrix
- Test edge cases and boundary conditions

**Integration Testing:**
- Test multi-policy interactions
- Test cross-tenant access attempts
- Test privilege escalation attempts
- Test concurrent access scenarios

**Adversarial Testing:**
- Simulate malicious client behavior
- Test UUID enumeration attacks
- Test direct API bypass attempts
- Test SQL injection attempts

## Edge Function Security Boundaries

### invite-member Function

**Security Boundaries:**
1. **Authentication**: Requires valid JWT token
2. **Authorization**: Checks organisation membership and role
3. **Input Validation**: Validates email format and role values
4. **Token Security**: Generates secure tokens, stores only digests
5. **Rate Limiting**: Checks for existing pending invitations
6. **Audit Logging**: Creates audit event for invitation creation

**Privilege Model:**
- Uses service role key for database operations
- Authorization logic precedes any privileged operations
- Input validation before database operations
- No elevated privileges exposed to client

**Attack Mitigations:**
- **Token Theft**: Tokens are one-time, expire in 7 days
- **Email Spoofing**: Email validation before invitation creation
- **Rate Limiting**: Duplicate invitation detection
- **Privilege Escalation**: Role validation before creation

### external-webhook Function

**Security Boundaries:**
1. **Signature Verification**: HMAC-SHA256 with timing-safe comparison
2. **Timestamp Validation**: 5-minute window to prevent replay
3. **Idempotency**: Event ID tracking prevents duplicate processing
4. **Input Validation**: Validates required headers and payload
5. **Error Handling**: Generic error messages prevent information leakage

**Privilege Model:**
- Uses service role key for database operations
- No authentication required (webhooks are unauthenticated)
- All security via signature verification
- Minimal database operations per event

**Attack Mitigations:**
- **Signature Forgery**: HMAC verification with secret
- **Replay Attacks**: Timestamp window + event ID tracking
- **Timing Attacks**: Timing-safe signature comparison
- **Header Injection**: Required header validation

### Edge Function Security Best Practices

1. **Minimal Privilege**: Use service role only when necessary
2. **Input Validation**: Validate all inputs before processing
3. **Error Handling**: Generic error messages, no stack traces
4. **Audit Logging**: Log all security-relevant events
5. **Rate Limiting**: Implement rate limiting for public endpoints
6. **Secret Management**: Never hardcode secrets, use environment variables
7. **Dependencies**: Keep dependencies updated, vet third-party code

## Authentication and Authorization

### Authentication Flow

```
1. User signs up/logs in via Supabase Auth
2. Supabase returns JWT token
3. Client stores JWT token
4. Client includes JWT in API calls
5. Supabase validates JWT signature and claims
6. auth.uid() available in RLS policies
7. Authorization decisions based on auth.uid()
```

### Authorization Model

**Identity Source:**
- `auth.uid()` is the single source of truth for user identity
- Never trust client-supplied user IDs
- Never use user-editable metadata for authorization

**Role Storage:**
- Roles stored in database tables (organisation_memberships, project_memberships)
- Roles never derived from JWT claims
- Roles can only be changed by authorized operations

**Authorization Hierarchy:**
```
auth.uid() → profiles → organisation_memberships → organisation
                                      ↓
                               project_memberships → projects
                                      ↓
                                    tasks/comments
```

### Session Management

**JWT Lifetime:**
- Default: 1 hour access token
- Refresh token: Longer lifetime (configurable)
- Automatic refresh via Supabase client

**Session Revocation:**
- Revoke all sessions: `auth.admin.deleteUser()`
- Revoke specific session: Session management in Supabase Auth
- Security events trigger session review

**Multi-Device Support:**
- Users can have multiple active sessions
- Each session has independent JWT
- Compromise of one session doesn't affect others

## Known Residual Risks

### High Priority

1. **Service Role Compromise**
   - **Risk**: Edge Function compromise gives full database access
   - **Mitigation**: Strict input validation, minimal function scope
   - **Monitoring**: Audit all service role usage

2. **JWT Token Theft**
   - **Risk**: Stolen JWT allows access until expiration
   - **Mitigation**: Short token lifetime, secure storage
   - **Monitoring**: Anomaly detection on token usage

3. **Database Compromise**
   - **Risk**: Direct database access bypasses all controls
   - **Mitigation**: Network security, access controls, encryption
   - **Monitoring**: Database access logging

### Medium Priority

1. **Invitation Token Interception**
   - **Risk**: Email interception exposes invitation token
   - **Mitigation**: Token expiration, email binding
   - **Monitoring**: Failed invitation attempts

2. **Storage Path Prediction**
   - **Risk**: UUID prediction could allow file access
   - **Mitigation**: UUIDs are cryptographically random
   - **Monitoring**: Failed file access attempts

3. **Webhook Secret Compromise**
   - **Risk**: Compromised secret allows webhook forgery
   - **Mitigation**: Regular secret rotation
   - **Monitoring**: Webhook signature failures

### Low Priority

1. **Brute Force Attacks**
   - **Risk**: Automated guessing of credentials
   - **Mitigation**: Rate limiting, account lockout
   - **Monitoring**: Failed login attempts

2. **DDoS Attacks**
   - **Risk**: Service availability impact
   - **Mitigation**: Rate limiting, caching, CDN
   - **Monitoring**: Traffic anomaly detection

3. **Social Engineering**
   - **Risk**: Users tricked into revealing credentials
   - **Mitigation**: User education, MFA
   - **Monitoring**: Unusual account activity

## Security Best Practices

### Development

1. **Never trust client input**: Validate all inputs at server level
2. **Use parameterized queries**: Prevent SQL injection
3. **Enable RLS on all sensitive tables**: Default deny access
4. **Test adversarial scenarios**: Assume malicious users
5. **Review security implications**: Consider security in all changes

### Deployment

1. **Environment separation**: Different configs for dev/staging/prod
2. **Secret management**: Use proper secret management services
3. **Monitoring and logging**: Comprehensive security event logging
4. **Regular updates**: Keep dependencies and Supabase updated
5. **Security reviews**: Regular security audits and penetration testing

### Operations

1. **Incident response**: Have security incident response plan
2. **Backup and recovery**: Regular backups, tested recovery procedures
3. **Access controls**: Least privilege access for administrators
4. **Change management**: Security review for all changes
5. **Compliance**: Adhere to relevant security standards (SOC2, GDPR, etc.)

### Compliance Considerations

**Data Protection:**
- GDPR compliance for EU user data
- Data retention policies
- Right to deletion implementation
- Data breach notification procedures

**Audit Requirements:**
- Comprehensive audit trail
- Immutable audit logs
- Regular audit log reviews
- Compliance reporting

**Security Standards:**
- SOC2 Type II compliance
- ISO 27001 security practices
- OWASP security guidelines
- Industry-specific requirements

This security model provides defense in depth with multiple layers of protection, monitoring, and incident response capabilities.