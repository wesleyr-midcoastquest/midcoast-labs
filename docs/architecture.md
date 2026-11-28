# MidCoast Lab Architecture Program
## Print-Ready Executive Export
### Version 1.6

> v1.6 (Nov 2026): several labs may share a cluster: pool, role, tag and provisioning
> user are per-site inventory values (defaults unchanged for existing sites); the
> provisioning role may snapshot and roll back (for CERT), and the pipeline refuses to
> run during a CERT scenario; Reset-LabLedger.ps1 after a teardown. Rationale:
> docs/decisions.md (1.6 sections).
>
> v1.5 (Nov 2026): MGMT-00 is set up by scripts (repo, vault, domain join, post-join rules)
> and may join the tailnet during its install with a one-time key; git identity comes from
> `site.yaml`; `Build-LabTemplate -Template` takes any inventory template key; every script
> is listed in docs/scripts.md. Rationale: docs/decisions.md (v1.5 sections).
>
> v1.4 (Nov 2026): standard accounts live in the `People` OU (`Users` clashes with the
> built-in container); fixes from the first real build (docs/decisions.md, CHANGELOG.md).
>
> v1.3 (Oct 2026): VMs are linked clones of versioned templates; memory ballooning;
> DCs sized at 4 GB / 50 GB and ADES at 6 GB.
>
> v1.2 (Oct 2026): the inventory is split into the product (`lab.yaml`, the same at every
> site) and the site (`site.yaml`: domains, subnet, Proxmox placement, VMID base), so the
> lab can be built by another engineer on their own Proxmox, domain and tenant. Addresses,
> VMIDs and domain names in this document are the example site's (`site/site.yaml`).
>
> v1.1 (Oct 2026): AD domain is a subdomain of a domain the site owns (not `.local`); the lab subnet is a dedicated /24; the
> OU structure is tiered; host naming uses a two-digit year; DC and MGMT addresses and VMIDs
> became slot pools so they can be replaced. Rationale: docs/decisions.md.

---

# Executive Summary

MidCoast Lab is a fully automated hybrid identity laboratory designed to demonstrate modern infrastructure engineering practices through Infrastructure as Code, automated validation, repeatable deployment, and recovery-by-rebuild operational philosophy.

The platform combines:

- Active Directory
- Microsoft Entra ID
- Proxmox Virtualization
- Terraform
- Packer
- PowerShell Automation

into a governed, repeatable architecture capable of rebuilding itself from source control and inventory configuration.

The environment is intentionally optimized for:

- Repeatability
- Recoverability
- Traceability
- Simplicity
- Validation

The objective is not simply to deploy infrastructure, but to create infrastructure that can be consistently recreated, validated, reviewed, and handed to another engineer without requiring tribal knowledge.

---

# Architectural Principles

## Source of Truth

All infrastructure originates from the inventory:

```text
inventory/lab.yaml     the product: what the lab is (same at every site)
site/site.yaml         the site: where it runs (domains, subnet, Proxmox, VMID base)
```

Together they are authoritative. They are merged into one resolved inventory, which
everything else reads; neither file repeats a value the other holds.

Terraform, PowerShell, validation scripts, build systems, and documentation derive their configuration from inventory.

This prevents:

- Configuration drift
- Duplicate configuration
- Conflicting implementations

When a change is required, inventory changes first.

Automation consumes those changes.

---

## Automation First

The platform rejects manual infrastructure deployment wherever practical.

Deployment pipeline:

```text
Git
    ↓
Inventory Validation
    ↓
Packer
    ↓
Terraform
    ↓
Cloudbase-Init
    ↓
Bootstrap
    ↓
Role Configuration
    ↓
Validation
```

No infrastructure component should require undocumented configuration.

Everything must be reproducible from source.

---

## Rebuild Over Repair

The core philosophical decision of the platform is:

```text
Role Survives.
Server Does Not.
```

A server has no inherent value.

A role has value.

When systems become unhealthy, the preferred workflow is:

```text
Validate
    ↓
Rebuild
    ↓
Redeploy
    ↓
Revalidate
```

rather than extensive troubleshooting or manual repair.

This keeps infrastructure aligned with source control.

---

## Separation of Concerns

Infrastructure provisioning and operating system configuration are distinct responsibilities.

### Terraform

Terraform owns:

```text
Virtual Machines

Storage

Networking (attaching VMs to the lab bridge)

Lifecycle
```

(v1.1: templates are built by Packer and put in place by `Build-LabTemplate.ps1`
through the Proxmox API; Terraform only clones from them. v1.3: each build is a new
template version, and VMs are linked clones of the version they were built from.)

### PowerShell

PowerShell owns:

```text
Active Directory

DNS

Configuration

Applications

Validation

Recovery
```

This separation improves:

- Testing
- Reusability
- Supportability
- Maintainability

---

# Identity Architecture

## Namespace Strategy

### Active Directory

```text
ad.example.com
```

(v1.1: changed from `midcoast.local`. `.local` collides with multicast DNS and can't
carry publicly trusted certificates; a subdomain of a domain the site owns avoids both.)

### NetBIOS

```text
EXAMPLE
```

### Microsoft Entra

```text
example.com
```

The design separates internal identity (`ad.example.com`) from cloud identity (`example.com`) while remaining compatible with Microsoft Entra synchronization: users sign in with `@example.com` UPNs, added to the forest as a UPN suffix.

---

## Organizational Structure

The Active Directory structure prioritizes simplicity and automation, and reserves
the shape of a tiered administration model (v1.1) so that enforcing it later never
means moving objects.

```text
Admin
├── Tier0                 identity control plane
│   ├── Accounts          Tier 0 admin accounts (jdoe-a)
│   ├── Groups            SG-ROLE-DomainAdmins
│   ├── ServiceAccounts   svc-labdeploy, svc-domainjoin
│   ├── Servers           ADES (Entra Connect)
│   └── Devices           MGMT (privileged admin workstation)
├── Tier1                 member servers
│   ├── Accounts
│   ├── Groups            SG-ROLE-ServerAdmins
│   └── ServiceAccounts
└── Tier2                 workstations and end users
    ├── Accounts
    └── Groups            SG-ROLE-HelpDesk

Servers                   Tier 1 member servers
├── Infrastructure
└── MemberServers

Workstations              Tier 2 (W11)

People                    standard user accounts (not "Users": that name is the built-in CN=Users)

Groups

Staging                   default landing zone for new computer objects

Domain Controllers        built-in; Tier 0 (DCs are never moved out of it)
```

Every account, group and machine role records its tier in inventory. Validation
rejects a role placed in an OU of another tier, and group membership that crosses
tiers. A join account with rights on Tier 0 OUs must itself be Tier 0.
Enforcement (logon restrictions, authentication policy silos) is deferred as
`MultiTierAdministration`; the structure is in place for it.

Every object location is deterministic.

Automation should never require manual object placement.

---

## Administrative Accounts

Every administrator receives:

```text
Standard User Account

Administrative Account
```

Administrative naming:

```text
<username>-a
```

Example:

```text
jdoe-a
```

Administrative permissions may only be assigned to administrative accounts.

---

## Service Accounts

Format:

```text
svc-<function>
```

Examples:

```text
svc-labdeploy     pipeline: DC promotion, demotion, FSMO moves

svc-domainjoin    delegated domain join

svc-entrasync     planned (Phase 3)
```

(Terraform and Packer don't use an AD account; they authenticate to Proxmox with
`terraform-prov@pve` API tokens.)

Naming immediately identifies purpose and ownership.

---

## Security Groups

Administrative groups:

```text
SG-ROLE-*
```

Examples:

```text
SG-ROLE-DomainAdmins

SG-ROLE-ServerAdmins
```

Resource groups:

```text
SG-ASSET-RSC-*
```

The model establishes a foundation for role-based access control.

---

## Local Administrator Strategy

Local administrative recovery remains available through:

```text
KeePass
    ↓
Domain Join
    ↓
LAPS Enrollment
    ↓
Automatic Rotation
```

Every domain-joined system receives a unique LAPS-managed credential.

---

# Infrastructure Architecture

## Network Design

Phase 1 uses a deliberately simple architecture: one subnet per site, with every
lab host at a fixed host number inside it. The example site uses:

```text
10.50.10.0/24
```

(v1.1: changed from `192.168.1.0/24`, the default on many home routers, so the lab can be
reached over Tailscale or a VPN from another network without the subnets colliding.)

Gateway:

```text
10.50.10.1
```

Bridge:

```text
vmbr1
```

### Address Assignments

```text
DC slots     10.50.10.10, .11, .12   (two active, one spare for replacement)

ADES         10.50.10.20

MGMT slots   10.50.10.30, .31        (one active, one spare for replacement)

W11          10.50.10.40
```

Static range: `10.50.10.10`–`10.50.10.49`, excluded from the router's DHCP pool.

At another site the host numbers (`.1` gateway, `.10`–`.49` lab range) stay the same
on that site's subnet.

The architecture prioritizes operational simplicity over segmentation complexity.

---

## Host Naming

Hostnames are generated rather than stored.

Format:

```text
<Role>-<YYMMDD>-<Sequence>
```

Examples:

```text
DC-261022-00

DC-261022-01

ADES-261022-00
```

Windows computer names are limited to 15 characters. With a four-digit year, ADES and
MGMT names would be 16 characters, so the build date uses a two-digit year. The longest
generated names (`ADES-YYMMDD-NN`, `MGMT-YYMMDD-NN`) are 14 characters. Inventory
validation rejects any role whose worst-case name exceeds 15.

Names such as `ADES`, `W11` or "DC slot A" elsewhere in this document refer to roles
and slots, not hostnames. A DC's actual hostname is generated, e.g. `DC-261022-00`.

The hand-built first MGMT keeps the fixed name `MGMT-00`; every pipeline-built
machine uses the generated format.

The build date becomes part of operational metadata and allows rebuilt systems to be distinguished from previous deployments.

---

## VM Allocation

Each site has a `vmid_base`; every lab VMID is an offset from it. The lab owns the
150-ID block `vmid_base` … `vmid_base + 149`.

Infrastructure range: `+0` … `+99`. Template range: `+100` … `+149`. Templates are
versioned (v1.3): each build takes the next free VMID in its family's range, and a
superseded version is deleted once no VM is cloned from it.

Assignments (offset → example site, `vmid_base: 100`):

```text
+0..+2     100-102  DC slots A, B, C

+10        110      ADES

+20..+21   120-121  MGMT slots A, B (A = the hand-built MGMT-00)

+40        140      W11

+100..+123 200-223  WIN2022-TEMPLATE versions (WIN2022-TEMPLATE-<YYMMDD>-<NN>)

+124..+147 224-247  WIN11-TEMPLATE versions

+148..+149 248-249  template build staging (WIN11, WIN2022)
```

This provides predictable allocation and prevents collisions. Before anything is
created, the site pre-flight checks that every ID in the block is free or already the
lab's.

---

## Proxmox Design

Terraform interacts with Proxmox using a dedicated service account.

```text
terraform-prov@pve
```

(v1.6: the pool, provisioning role, VM tag and this user are per-site names from the
resolved inventory; new sites get `…-<site>` names so several labs can share a cluster,
each on its own network segment and VMID block. Sites built before 1.6 keep these names.)

Terraform never uses root credentials.

Permissions are limited to:

```text
VM Provisioning

VM Modification

Template Cloning
```

This satisfies least-privilege principles.

---

# Build Architecture

## Golden Templates

The environment deploys from two approved templates.

```text
WIN2022-TEMPLATE

WIN11-TEMPLATE
```

Templates contain:

```text
Windows Updates

PowerShell 7

Cloudbase-Init

QEMU Guest Agent
```

Templates intentionally do not contain:

```text
Domain Membership

Application Configuration

Environment-Specific Data
```

Since 1.7 they don't contain site data either: the firewall rule that lets MGMT in is
made on first boot from the clone's own subnet, so other labs on the same node can clone
them (`site.yaml templates.shared_from`; see decisions.md, "Shared templates").

---

## Packer

Packer is the authoritative image creation platform.

Benefits:

- Repeatable image generation
- Source-controlled template definitions
- Recoverable template lifecycle
- Consistent builds

Template creation itself is treated as code.

---

## Cloudbase-Init

Cloudbase-Init is responsible for first-boot execution.

Responsibilities:

```text
Metadata Processing

Host Configuration

Bootstrap Launch
```

It then opens WinRM over HTTPS, reachable only from the MGMT slot addresses. MGMT pushes
the platform, the deployment metadata and the role's secrets, and starts:

```text
bootstrap.ps1
```

which begins platform configuration. (v1.1: the payload is pushed rather than carried in
cloud-init user-data, so no secrets are stored on Proxmox; see decisions.md.)

---

# Bootstrap Architecture

All systems follow a common startup workflow.

```text
Cloudbase-Init
        ↓
MGMT pushes platform + metadata + secrets
        ↓
bootstrap.ps1
        ↓
Role Script
        ↓
Validation Script
```

---

## Cloudbase-Init

Sets the hostname from the Proxmox config drive.

Prepares the operating system (extends the system volume).

Opens WinRM/HTTPS to MGMT, which starts bootstrap.

---

## Bootstrap

Loads:

```text
Inventory

Metadata

Runtime Modules
```

Determines role identity.

Launches role-specific configuration.

---

## Role Script

Examples:

```text
dc.ps1          built

mgmt.ps1        built (with mgmt-tools.ps1, the shared toolchain installer)

ades.ps1        planned (Phase 3)

w11.ps1         planned (Phase 2)
```

Role scripts install and configure workloads.

---

## Validation

Examples:

```text
dc-validation.ps1     built

mgmt-validation.ps1   built

ades-validation.ps1   planned
```

Validation confirms deployment success before progression.

---

# Runtime Architecture

The platform standardizes reusable PowerShell modules.

## Lab.Logging

Provides:

```text
Logging

Retention

Transcripts
```

---

## Lab.Metadata

Provides:

```text
Build Metadata

Runtime Metadata
```

---

## Lab.Inventory

Provides:

```text
Inventory Access

Domain Access

Hostname Generation
```

---

## Lab.System

Provides:

```text
System Utilities

Reboots

Configuration Tasks
```

---

## Lab.Validation

Provides:

```text
Validation Framework

Reporting

Severity Mapping
```

---

## Lab.AD

Provides:

```text
Active Directory Operations
```

---

## Lab.Entra

Provides:

```text
Entra Synchronization Functions
```

---

# Deployment Architecture

## Phase 1

Directory Services

```text
DC (two instances: the forest root, then a replica)
```

Validation includes:

```text
Forest
DNS
SYSVOL
Replication
FSMO
```

---

## Phase 2

Management

```text
W11
```

(MGMT is not a Phase 2 build: the hand-built MGMT-00 is joined to the domain by `setup/mgmt/Join-LabDomain.ps1`
after Phase 1, and later MGMTs are built by MGMT rotation, already domain-joined.)

Validation includes:

```text
Authentication

Policy Application

Administration Tools
```

---

## Phase 3

Hybrid Identity

```text
ADES
```

Validation includes:

```text
Connector Health

Synchronization

Tenant Connectivity
```

---

# Validation Architecture

Validation is considered part of the architecture.

Infrastructure that cannot validate itself cannot reliably recover itself.

---

## Inventory Validation

### Syntax

Valid YAML.

### Schema

Required structure.

### Semantic

Business rules.

Examples:

```text
Duplicate VMIDs

Duplicate IPs

VMIDs or addresses outside the site's block or subnet

Site values left as placeholders

Invalid Naming

Missing Templates
```

---

## Runtime Validation

Role-specific validation measures operational health.

Examples:

```text
DNS Resolution

Replication

Authentication

Synchronization
```

---

## Severity Model

Every validation result receives a severity.

### Critical

```text
Stop Deployment

Evaluate Rollback
```

### High

```text
Administrative Review
```

### Medium

```text
Warning
```

### Low

```text
Informational
```

---

# Recovery Architecture

The platform intentionally supports multiple recovery models.

---

## Level 1

Snapshots

Fastest recovery.

Least validation.

Whole-lab rollback only. A single DC is never restored from a snapshot; it is rebuilt.

---

## Level 2

Backups

Traditional restoration.

Moderate validation.

---

## Level 3

Rebuild

Using:

```text
Git

Inventory

Templates

Terraform

PowerShell
```

Highest confidence.

Preferred approach.

---

## Rollback Framework

Validation IDs map directly to recovery actions.

Example:

```text
REPL-001
    ↓
RebuildDC (the affected DC is rotated out and replaced)
```

Every failure carries its recovery action in the validation report. Acting on it is
manual: for `RebuildDC`, run DC rotation (`Invoke-LabDcRotation.ps1`; `-Replace <name>` for the affected DC).

This transforms recovery from guesswork into architecture.

---

# Operations Architecture

## Logging

Location:

```text
C:\ProgramData\MidCoastLab\Logs
```

Categories:

```text
Bootstrap

Validation

Installers

Cloudbase-Init
```

Retention:

```text
90 Days
```

---

## Terraform State

Initial state location:

```text
The active MGMT instance (C:\MidCoastLab\state), handed over on MGMT rotation
```

Future migration:

```text
Terraform Cloud

Azure Storage

S3 Compatible Storage
```

---

## Updates

Templates are rebuilt:

```text
Monthly
```

or after critical security updates.

This keeps deployments aligned with modern patch levels.

---

# Deferred Architecture

## Certificate Services

AD CS is intentionally excluded from Phase 1.

Benefits:

```text
Reduced Complexity

Reduced Maintenance

Faster Deployment
```

Future phases may revisit:

```text
PKI

Certificate Authentication

TLS Automation
```

---

# Final Position

MidCoast Lab is not designed to demonstrate individual technologies.

It is designed to demonstrate a complete operational philosophy:

```text
Inventory Driven

Automation First

Validation First

Rebuild Over Repair

Infrastructure as Code
```

Every implementation decision should be evaluated against those principles.

If a design choice increases manual effort, introduces configuration drift, or reduces recoverability, it works against the core objectives of the platform.

The architecture succeeds when a new engineer can clone the repository, review the inventory, execute the deployment pipeline, and produce a validated hybrid identity environment without relying on undocumented knowledge.