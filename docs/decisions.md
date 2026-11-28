# Decisions

Changes from the original architecture document and inventory (both v1.0), and the
design choices behind the implementation. `docs/architecture.md` (v1.3) already
reflects these changes. Addresses and VMIDs below are the example site's
(`10.50.10.0/24`, `vmid_base: 100`); other sites have the same host numbers and
offsets on their own subnet and base. Inventory changes are marked `CHANGED` or
`ADDED` in `inventory/lab.yaml`.

## Design decisions (Oct 2026)

| Topic | Decision | Why |
|---|---|---|
| Who builds the first pieces | **MGMT-00 is hand-built once** and runs the pipeline until the first MGMT rotation replaces it | Something must exist before any template can be built; MGMT-00 joins the domain after Phase 1 |
| DC addressing | **Three-slot pool** (A/B/C = VMIDs 100–102, .10–.12), two active | During a rotation the old and new DC overlap, so they can't share an IP or VMID |
| Hostnames | **`<Role>-<YYMMDD>-<Sequence>`** (two-digit year), e.g. `DC-261023-00`, `ADES-261023-00` | Windows computer names are limited to 15 characters. With a four-digit year, ADES and MGMT names would be 16; with two digits the longest is 14 |
| First-boot network | **Router DHCP on the lab bridge**, then bootstrap sets the static IP | Avoids depending on Proxmox's cloud-init network data for Windows |
| AD domain name | **A subdomain of a domain the site owns** (example site: `ad.example.com`, NetBIOS `EXAMPLE`; was `midcoast.local`) | The forest is the one thing rotation never rebuilds, so its name has to be right before Phase 1. `.local` collides with multicast DNS (Bonjour/Avahi) and can't carry publicly trusted certificates; a subdomain of a domain the site owns avoids both |
| Lab subnet | **A dedicated /24** (example site: `10.50.10.0/24`; was `192.168.1.0/24`), same host numbers | `192.168.1.0/24` is the default on many home routers; managing the lab over Tailscale from such a network would route to the wrong place. `10.42.0.0/16` was avoided too (k3s default pod network) |
| Administrative tiering | **Tiered OU structure and per-object tiers now; enforcement later** | Retrofitting tiers means moving objects and re-linking GPOs, delegation and LAPS. Recording the tiers costs nothing before anything is built |
| Configuration management | **No PowerShell DSC for now**; idempotent PowerShell scripts | See "PowerShell DSC" below |
| Replacing MGMT | **Pipeline replaces MGMT after the first hand-build**: two-slot pool (A/B = VMIDs 120–121, .30–.31), handover in stages | Removes the last hand-maintained machine (and its 90-day evaluation clock) from outside the pipeline |
| VM sizing | **DCs 4 GB / 50 GB, ADES 6 GB** (were 8 GB / 80 GB, 8 GB) | A lab directory with a handful of objects is comfortable in 4 GB; Phase 1 peak RAM drops from 32 GB to 24 GB |
| Memory ballooning | **On**, with a per-role floor (`memory_min_mb`) | Proxmox can reclaim memory from idle VMs when the host runs short. A cushion only: the host is still sized for the maximum |
| Clones | **Linked clones of versioned templates** (`clone_mode: linked`; a site can set `full`) | Each VM stores only its changes from the template, roughly halving disk use. Proxmox can't delete a template that has linked clones, so every build makes a new template version instead of replacing the old one |
| Server Core for DCs | **Deferred** | Would save about 0.5–1 GB RAM and a few GB of disk per DC and suits remotely managed DCs, but needs a second Server 2022 template (ADES must stay on Desktop Experience for Entra Connect). Revisit later |
| Portability | **Product / site split**: `lab.yaml` is the same at every site, `site.yaml` holds what differs; addresses are host numbers and VMIDs are offsets from a site `vmid_base` | So the repo can be handed to another engineer with their own Proxmox, domain and tenant, and every site stays the same lab |

## Inventory changes (v1.0 → v1.1)

- **DCs**: two fixed entries → one `DC` role with `instances: 2` and `slots`.
  `fsmo_owner` removed: the first DC creates the forest and holds FSMO; rotation moves FSMO.
- **`network.dns.primary/secondary` removed**: lab DNS servers are the active DCs' addresses.
- **Network**: `192.168.1.0/24` → a dedicated /24 (example site `10.50.10.0/24`); every address keeps its host number
  (DCs `.10–.12`, ADES `.20`, MGMT `.30–.31`, W11 `.40`, gateway `.1`). The gateway on
  the lab bridge has to be moved to the new subnet by hand. Validation warns about subnets that
  commonly collide (default home-router ranges, Docker, k3s).
- **Tiering**: `Admin/Users` and `Admin/Groups` became `Admin/Tier0|1|2` with `Accounts`,
  `Groups` and `ServiceAccounts` (plus `Servers` and `Devices` in Tier 0). The top-level
  `ServiceAccounts` OU and the unused `Servers/DomainControllers` OU were removed. New:
  `tiering` (tiers, and the tier of each computer OU), `tier` on every administrator,
  service account, group and server role, and `groups` on administrators (replacing the
  hard-coded Domain Admins membership). `groups.administrative` entries became
  `{name, tier}`. Placement: ADES → `Admin/Tier0/Servers`, MGMT → `Admin/Tier0/Devices`.
- **`identity.active_directory.domain`**: `midcoast.local` → a subdomain of the site's own domain (example site `ad.example.com`). Inventory
  validation now rejects single-label and `.local` domain names. Users still sign in as
  `@<tenant domain>` (e.g. `@example.com`); the forest gets that as a UPN suffix. Keep the `ad.` subdomain out of
  public DNS (it lives only on the DCs), so internal and external DNS never overlap.
- **Added**: `naming`, `environment.time_zone`, `network.static_range`, `network.dhcp`,
  `network.ntp`, `proxmox.node` / `endpoint` / `insecure_tls`, a separate Packer token,
  template `build` settings, AD forest/domain mode, site, DNS forwarders, LAPS settings,
  administrators, service accounts, group nesting, computer placement, secret names,
  `terraform.state.path`.
- **Phases** list roles instead of systems (DCs are slot-based, so names change).
- **MGMT**: the fixed entry became a two-slot pool (A/B = VMIDs 120–121, `.30`–`.31`)
  with `instances: 1`. An `initial` block describes the hand-built MGMT-00 (slot A,
  `origin: manual`), and `handover` and `software_versions` were added. The Windows 11
  template gained a `build` section.
- **`build_date: dynamic`** is kept. Each instance's date is assigned once and pinned in
  `inventory/instances.yaml`, so names stay stable across Terraform runs. The
  architecture's "hostnames are generated rather than stored" holds in spirit: the
  ledger records the generated name together with the date, sequence and slot it was
  derived from, and inventory validation checks every recorded name against that
  derivation.

## Inventory changes (v1.1 → v1.2): product and site

- **`inventory/site.yaml`** (new) holds everything that differs between installations:
  site name and time zone, AD domain and NetBIOS name, Entra tenant domain,
  administrators, subnet, gateway, DNS forwarders, NTP, Proxmox cluster/node/endpoint/TLS,
  bridge, storages, `vmid_base`, ISO names. `site.template.yaml` is the blank copy.
- **`inventory/lab.yaml`** keeps only the product. Validation refuses site keys in it,
  and product keys in `site.yaml`.
- **Addresses are host numbers**: every server and slot has `host` (DC slots 10/11/12,
  ADES 20, MGMT slots 30/31, W11 40) and the lab range is `start_host: 10`–`end_host: 49`.
  The full address is the site subnet plus the host number.
- **VMIDs are offsets**: `vmid_offset` on servers and slots (0–99) and templates
  (100–149, staging VMs 148–149), added to the site's `vmid_base`. The example site
  uses base 100, so its VMIDs are unchanged.
- **Resolved inventory**: `Resolve-LabInventory` merges the two into the same shape as
  before (full `ipv4` and `vmid` everywhere). The orchestration writes it to
  `inventory/resolved/inventory.json` (gitignored) for Terraform and Packer; guests get
  it as `inventory.json` in their payload, as before. For the example site every
  v1.1 value resolves unchanged (the resolved file only adds `site`, `vmid_base` and the
  `host` / `vmid_offset` keys it was computed from), apart from the version number.
- **Subnet is exactly a /24** network address (host numbers are the last octet; the
  reverse DNS zone is the three-octet zone).
- **New checks**: offline (`Test-LabInventory.ps1`): placeholders left in `site.yaml`,
  /24 network address, gateway inside the subnet but outside the lab range,
  `vmid_base` ≥ 100, ISOs on the ISO storage, a Windows (not IANA) time zone ID, a
  site name usable as a folder name, and a ledger that doesn't fit the
  site (an inherited `instances.yaml`). Live (`Test-LabSite.ps1`, run by every pipeline
  entry point): node, storages and their content types, bridge, ISOs, pool, **every lab
  VMID free or already the lab's**, and **nothing outside the lab answering on a lab
  address**. Root-side (`proxmox-setup.sh check`): the same Proxmox checks with a view of
  every VM on the cluster, before anything is created. The hand-built MGMT-00 counts as
  the lab's by VMID and name, before it is tagged or in the ledger.
- **Site kit**: `setup/New-LabSiteKit.ps1` turns the runbook template (`docs/runbook.md`, `docs/mgmt-00.md` before v1.5,
  `{{token}}` placeholders) and the Proxmox setup script into a filled-in
  `out/site-kit/<site>/`. `proxmox-setup.sh` replaces `New-ProvisioningAccount.sh` and
  also creates the MGMT-00 VM, so the first build has no hand-typed site values.
- **Fixed product names**: the pool (`MidCoast-Lab`), role, `terraform-prov@pve`, vault
  name and `midcoast-lab` tag are the same at every site. One lab per Proxmox cluster.
  (Superseded in 1.6: see "Several labs on one cluster" below.)

## Inventory changes (v1.2 → v1.3): sizing, ballooning, linked clones

- **Sizes**: DC `memory_mb` 8192 → 4096 and `disk_gb` 80 → 50; ADES `memory_mb`
  8192 → 6144.
- **`memory_min_mb`** (new, per role): ballooning floor. DC 2048, ADES 4096, MGMT 4096,
  W11 2048. Validation: at least 1024 and not above `memory_mb`.
- **`proxmox.clone_mode`** (new): `linked` in lab.yaml; a site may set `full` in
  site.yaml. Validation requires `storage.templates` = `storage.virtual_machines` for
  linked clones; the live pre-flight and `proxmox-setup.sh check` require the storage
  type to be LVM-thin, ZFS or RBD.
- **Templates**: `vmid_offset` → `vmid_offsets: { first, last }` (WIN2022 100–123,
  WIN11 124–147); the resolved inventory has `vmid_first` / `vmid_last`. Staging VMIDs
  are unchanged (+148, +149).
- **Ledger**: new `templates:` list; instances gain `template_vmid` and `clone_mode`. Validation checks
  every pipeline-built instance is pinned to a listed version of its role's family, one
  current version per family, and template VMIDs inside their family's range.
- **Validation**: new `MEM-001` (balloon service running, Low).
- **OU `Users` → `People`**, with `placement.standard_users: People`. A top-level OU
  can't be named `Users`: the domain root already has the built-in `CN=Users` container,
  and AD requires names to be unique under a parent whatever the object type (found by
  the first real Phase 1 run). Validation now rejects top-level OUs named after any
  built-in root container.

## Design choices

**Instance ledger (`inventory/instances.yaml`).** `lab.yaml` is the design; the ledger
records what exists. The pipeline writes it and you commit it, so git history is the
build history. Terraform reads both files and nothing else.

**Push the payload, not cloud-init user-data.** Cloudbase-Init does metadata processing
(hostname), host configuration (extend C:) and bootstrap launch (a LocalScripts step that
opens WinRM/HTTPS to the MGMT slot addresses only). The orchestrator then pushes the platform, metadata
and that role's secrets over WinRM/HTTPS and starts `bootstrap.ps1`. Putting the payload
in user-data would have meant Proxmox snippets, which bpg/proxmox can only upload over
SSH, which would need a Linux account on the Proxmox node beyond `terraform-prov@pve`. It would
also have left secrets on Proxmox disks.

**Secrets.** KeePass is the source (SecretManagement vault on the active MGMT). Each guest gets
only its role's secrets, stored with DPAPI (machine scope) in a folder only SYSTEM and
Administrators can read. They are wiped when bootstrap finishes. The forest root's local
Administrator becomes the domain Administrator, so bootstrap sets its password from
KeePass before promotion.

**Windows PowerShell 5.1 inside guests.** AD DS deployment, DNS, Group Policy and LAPS
cmdlets are native to 5.1. PowerShell 7 is in the templates, as the architecture
requires, and the orchestrator on MGMT runs on it.

**Security context on DCs.** Bootstrap runs as SYSTEM. On a DC that is the DC's computer
account, which can't extend the schema, create GPOs or run dsacls. Domain configuration
therefore runs as the domain Administrator in a one-shot scheduled task. That is a real
logon with full network credentials, so SYSVOL writes and Kerberos work without the
limits of a remoting session. Validation runs as SYSTEM, so checks that reach the partner
DC never hit the remoting double hop. Pipeline accounts (`svc-*`, built-in Administrator)
don't expire, since they live in KeePass; human `-a` accounts follow domain policy.

**DSRM passwords** start as the KeePass value, then Windows LAPS rotates them and backs
them up to each DC's computer object (`Get-LapsADPassword -Identity <DC> -AsPlainText`).
After the first rotation, the KeePass DSRM entry is only the seed for new DCs.

**Validation catalog.** Checks report pass/fail only. `platform/validation/catalog.psd1`
maps each ID to its severity and recovery action (`REPL-001 → RebuildDC`), as in the
doc's rollback framework.

**Templates are versioned, not overwritten** (v1.3; v1.1–1.2 swapped one template in
place). Packer builds at a staging VMID (`+149` for WIN2022-TEMPLATE, `+148` for
WIN11-TEMPLATE). Only on success is the staging VM full-cloned to the next free VMID in
the template's range as `<family>-<YYMMDD>-<NN>`, which becomes the current version; the
previous version is marked superseded. A failed build never leaves you without a
template. See "Linked clones and template versions" below.

**Least privilege on Proxmox.** `terraform-prov@pve` gets a custom role on the pool, the
two storages and the lab bridge only, plus read-only on the node, and is reached by
API tokens (separate ones for Terraform and Packer). No root, no SSH.

**DCs stay in the built-in Domain Controllers OU**, where the Default Domain Controllers
Policy is linked. That's why the `Servers/DomainControllers` OU from v1.0 was removed.

**Snapshots.** Kept as a recovery method for whole-lab rollback only. A single DC is
never restored from a snapshot; it is rebuilt by rotation.

**Terraform state on the active MGMT**, outside the repo (`C:\MidCoastLab\state`). Back it
up. Losing it isn't fatal, since the VMs can be imported, but it's tedious. A MGMT rotation
copies it to the new MGMT. There is no `backend` block: `Invoke-LabTerraform` passes the
path with `-state`, so the state file never lands in the repo working tree and the
location comes from inventory. `CentralTerraformState` remains deferred; it will add a
remote backend.

## Linked clones and template versions

Since v1.3, Terraform creates every VM as a **linked clone** of a template: the VM's disk
is a thin snapshot of the template's, so it stores only what differs. Two DCs cost about
one template plus a few GB each, instead of two full copies.

A template with linked clones can't be deleted (Proxmox refuses, and the clones would
lose their base). So templates are **versioned**:

- Each template family has a VMID range (`vmid_offsets` in lab.yaml): WIN2022-TEMPLATE
  `+100`…`+123`, WIN11-TEMPLATE `+124`…`+147`. Each build takes the next free VMID there.
- The ledger (`instances.yaml`) has a `templates:` list: name, family, VMID, build date,
  and `current` or `superseded`. One version per family is current.
- Every instance records `template_vmid`, the version it was cloned from, when it is
  allocated. Terraform clones from that, so building a new version never changes an
  existing VM; only new VMs (the next rotation) get it.
- `Remove-LabUnusedTemplates` deletes superseded versions that no instance uses any
  more. It runs before and after each template build and after a MGMT rotation. It
  never deletes the current version, re-checks the VM's name and tag first, and keeps
  the version if Proxmox refuses.
- The range holds 24 versions per family. That only fills if VMs are never rotated off
  old versions; the build then stops and says so.

**Trade-offs.** With the lab's raw disks, linked clones need LVM-thin, ZFS or Ceph RBD
(directory or NFS storage could only do them with qcow2 disks), with the templates and VMs
on the same storage. On node-local storage (`local-lvm`, `local-zfs`), Proxmox can't
migrate a linked clone, so the lab's VMs and their template versions stay on
`proxmox.node`: node maintenance means shutting the lab down (Ceph RBD avoids this). The
clone mode is recorded per instance in the ledger (`clone_mode`), so changing
`proxmox.clone_mode` later only affects VMs built after the change; existing ones change
over as they rotate. Validation checks both and points to `proxmox.clone_mode: full` in
site.yaml for storage that can't do it (full clones work exactly as before, with the
same versioning). A linked clone depends on its template's disk, so losing the template
loses its clones; with rebuild-over-repair that is recovered by rebuilding the template
and rotating, but it's another reason to back up the VM storage.

**Ballooning.** Each role has `memory_mb` (maximum) and `memory_min_mb` (floor). The
templates install and enable the VirtIO balloon service (`build-bootstrap.ps1` checks
for it), and `MEM-001` (Low) reports it in each validation run. Proxmox only balloons
when the host passes about 80% memory use.

## Guest identity

Found in the first real Phase 1: both new DCs reported the same DHCP address, and the
orchestrator pushed DC-00's setup to whichever machine answered there, which was VM 1001.
It now never trusts an address alone:

- **MAC check.** A WinRM session is only used if the guest has the VM's MAC address, read
  from the VM's Proxmox config. Another machine on the same address is ignored, with a
  warning.
- **Addresses from the guest agent.** Each attempt asks the VM's QEMU guest agent for its
  current IPv4 addresses, as well as the static address and Terraform's report.
- **Metadata check.** A guest that already has lab metadata must have been set up as this
  instance (hostname and VMID); otherwise the run stops instead of following another
  instance's bootstrap.

**Likely root cause: a cached DHCP lease in the template.** Sysprep keeps the build VM's
lease, so each clone first asks to keep that address; a non-authoritative DHCP server
(dnsmasq's default) stays silent and Windows keeps it. The template now deletes the
cached lease before sysprep, and the lab's DHCP server should be set authoritative.

A run that already reached the wrong machine is recovered by rebuild: delete both VMs,
remove their ledger entries, and run the phase again.

## Administrative tiering

Tier 0 is everything that controls identity: the DCs, Entra Connect (ADES, which can write
to the directory and holds sync credentials), MGMT (it holds the pipeline's credentials and
can rebuild any DC), and the accounts and groups that administer them. Tier 1 is member
servers; Tier 2 is workstations and end users.

**What's implemented now:** the OUs, each object created in its tier's OU, and validation
that keeps the model consistent:
- a role's placement OU must be in the role's tier,
- membership never crosses tiers,
- every tier has its Accounts and Groups OUs,
- the domain-join account, which can create objects in Tier 0 OUs, must be Tier 0.

Domain-join delegation and the LAPS policy are applied to every computer OU (derived from
inventory), so new tiers and placements pick them up automatically.

**What's deferred** (`MultiTierAdministration`, `tiering.enforced: false`): stopping
higher-tier accounts from signing in to lower-tier machines, through Group Policy user
rights ("Deny log on…") or authentication policy silos, plus Protected Users for Tier 0
admins. That last one is deliberately not on yet: Protected Users blocks NTLM, and the
pipeline and Remote Desktop by IP rely on it until AD CS provides certificates for Kerberos
by name. Enforcing tiers later becomes a matter of GPOs linked to OUs that already exist.

**MGMT is Tier 0**, so it's treated as a privileged admin workstation: only Tier 0 admins
should sign in to it, and it shouldn't be used for browsing or email.

## PowerShell DSC

Desired State Configuration isn't used, and isn't needed with this design. Its main job
is to keep long-lived machines in their declared state, re-applying configuration
when they drift (`ApplyAndAutoCorrect`). That's repair. MidCoast Lab replaces rather
than repairs: every machine is built from source, validated, and rebuilt when it's
unhealthy or its evaluation runs out, so no machine lives long enough to drift far. The
role scripts are idempotent, so they get the property DSC is usually chosen for without
its overhead:

- **Credentials.** Compiled configurations must encrypt credentials with a per-node
  certificate (AD CS is deferred), or allow plain text. The pipeline instead pushes
  secrets over WinRM/HTTPS, keeps them in DPAPI, and wipes them when bootstrap finishes.
- **The hard parts aren't declarative.** Forest creation, promotion order, FSMO moves,
  demotion and the MGMT handover are sequences with checks between steps. They would stay
  scripts even with DSC.

**It may be added later**, and adding it is cheap because of the same design. A DSC
module goes into `platform/` (and its resources into the templates), and every machine
picks it up at its next rotation, with no retrofitting of running servers. The likely
fit is **drift detection, not correction**: a configuration in `ApplyAndMonitor` mode,
generated from `lab.yaml`, whose findings feed the validation catalog, so drift becomes
a severity that triggers a rebuild. `ActiveDirectoryDsc` resources map closely onto
`Lab.AD`, and the newer DSC v3 (no LCM, YAML/JSON documents) suits an inventory-driven
design. Check its AD resource coverage before choosing it.

## MGMT replacement

**Why a handover, not a rebuild.** MGMT holds the pipeline's state: the repo, the Terraform
state, the vault. It can't destroy itself and start over, so the old MGMT builds the new
one and hands over (Prepare), and the new one retires the old (Complete). Abort works
until the old VM is destroyed.

**What goes over.** Besides the pipeline's state, the handover copies CERT (if installed)
and the pipeline's logs: Complete destroys the old VM, and with it anything left behind
(issue #29). CERT is copied as a folder rather than cloned again, so the new MGMT keeps
its version, `cert.config.yaml` and module sources. Its run folders keep their own ACL
(only the account that ran CERT, and SYSTEM: they hold engagement passwords), which the
`C:\MidCoastLab` lockdown would otherwise reset. Old logs go under `Logs\Previous\<old MGMT>`
so two machines' logs don't mix and the new MGMT's `Validation\latest.json` stays its own.
A failed copy of either stops the handover, like the rest of it.

**Why a slot pool.** Every guest's WinRM firewall is baked in at template build time with
the MGMT addresses it trusts. A single address would lock a replacement out of every
existing machine, so the templates trust both MGMT slot addresses.

**Hand-built MGMT-00 in the ledger.** `servers[MGMT].initial` describes it (slot A,
`origin: manual`). The pipeline records it in the ledger the first time it runs.
Terraform skips `origin: manual` entries, and Complete deletes such a VM through the
Proxmox API instead.

**One toolchain installer.** `platform/roles/mgmt-tools.ps1` is used by both the
hand-build and the MGMT role. It downloads directly from vendors rather than using winget,
which isn't reliably available to SYSTEM. HashiCorp binaries are checked against their
published SHA256SUMS.

**The lock.** After handover the old MGMT writes `C:\MidCoastLab\HANDOVER.lock`.
Terraform applies, template builds and phases all refuse to run while it exists, so the
two machines can't both change the lab with diverging state.

**Terraform guard.** Every `apply` is a saved plan that is inspected first. It is
refused if it would delete, delete-and-recreate, or remove a disk, EFI disk or TPM from
an instance the ledger marks active, or from the machine running it. It fails closed: if
the plan can't be read, nothing is applied. That protects the DCs from provider drift too.

**Handover folder ACL.** `C:\MidCoastLab` on a pipeline-built MGMT grants SYSTEM,
Administrators and `SG-ROLE-DomainAdmins`. The lab group is granted directly, because UAC
strips Administrators from a non-elevated token but leaves custom groups alone.

**Windows 11 template safeguards.** Store auto-updates are off during the build (per-user
app updates break sysprep), and unprovisioned per-user packages are removed before
sysprep. Automatic device encryption is disabled, or every clone would come up
BitLocker-encrypted, since the template has a TPM. The built-in Administrator is
re-enabled on first boot, because client SKUs disable it after sysprep.

## DC rotation

**Two stages with a checkpoint.** `Add` builds the replacement and moves everything onto
it (FSMO roles, the PDC emulator's external time source);
`Retire` demotes and destroys the old DC. Between them the old DC still runs as a third DC
that nothing depends on, so the change can be checked before anything is removed, and
`Abort` can still undo it. Same shape as the MGMT handover, for the same reason: the risky,
irreversible step is separate and last.

**Replace, never repair.** The new DC is a replica built from the current template, so
every rotation also brings the DC onto the latest patched template and restarts its
evaluation clock. The forest itself is never rebuilt.

**Addresses move with the slot.** The new DC takes the free slot of three (`.10`–`.12`),
so the active DCs change address with each rotation. The alternative, re-IPing the new
DC onto the old one's address after demotion, adds a risky step (a DC's address is in DNS,
replication metadata and every client's resolver cache) to save repointing clients, and
since LAB-261127-01 no lab client needs repointing anyway (next section). Machines outside
the lab that were pointed at a DC by hand are the exception; Add prints the new addresses.

**DNS clients use every DC slot (LAB-261127-01).** Until then the rotation repointed every
DNS client at the DCs active at the time, but it could repoint MGMT itself, the machine
running it, only from an elevated window; from a normal one MGMT was left with a retired
DC as one of its two DNS servers (issue #27). Now the lists come from the DC pool, not the
ledger, and never change: a machine that isn't a DC gets all three slot addresses in slot
order (A, B, C), in its build metadata and from `Join-LabDomain.ps1`; a DC gets the other
two slots, then loopback (still partners first, loopback last: `DNS-004`). One place
computes them, `Get-LabDnsClientServers` (Lab.Inventory). The cost is the empty slot: at
least two slots always hold a DC (three during a rotation), and when the server Windows
tries first doesn't answer it moves to the next after about a second and prefers the one
that answered for a while, so it's an occasional one-second lookup, not a failure; on a DC
that retry falls on its own lookups when its preferred partner is the empty slot. `MGMT-005`
passes when at least two of the slots answer WinRM/HTTPS and names the one that doesn't.
The rotation still sets each DC's list, which changes only DCs built before this release.
A slot address must never go to anything else: `Test-LabInventory` rejects another role on
it (`DuplicateIP`), every slot is inside the static range the router's DHCP pool must
exclude (`IPOutsideStaticRange`), and `Test-LabSite` reports anything outside the lab that
answers on a free lab address.

**Demote, don't delete.** A reachable DC is demoted (`Uninstall-ADDSDomainController`),
which removes its own objects cleanly. Only a DC that can't be reached is handled with
`-Force`: FSMO roles seized and `ntdsutil` metadata cleanup. After either, the leftover NS,
domain, `gc` and partition A records and the computer object are removed.

**Explicit credentials across the hop.** FSMO moves and demotion run in a remote session on
a DC but must talk to another DC; the session's own credentials can't make that second hop,
so the domain administrator credential is passed to those cmdlets explicitly.

## Remote Desktop to the DCs

DCs and MGMT turn on Remote Desktop (Network Level Authentication on) for the **lab
subnet**. The DCs are managed from MGMT (RSAT, PowerShell remoting); Remote Desktop is for
the cases a console session is simply quicker. The lab subnet holds only lab machines, so
this doesn't open a DC to the home LAN or the tailnet. Who may sign in stays AD's default
for DCs (Administrators). Checked by `RDP-001` (DCs) and `MGMT-007` (MGMT). WinRM stays
MGMT-only, since that's the pipeline's way in.

## Tailscale on MGMT (1.8)

**Why MGMT only.** Until 1.8 every DC and MGMT joined the tailnet, for a way into each
machine that doesn't depend on the lab's router or the subnet route. On a DC that cost
more than it gave, all of it there to keep a second adapter out of AD's DNS (issue #26):
the single-homing below, static domain-name and gc records the rotation has to remove, a
cleanup of stray Tailscale records and `DNS-005` to check for them, and a reusable auth key
at rest (the AuthKey policy and the watchdog) on every Tier 0 machine. So since 1.8 only
MGMT joins: lab.yaml has `tailscale: true` on the MGMT role and `tailscale: false` on DC;
a role without the value doesn't join (`Test-LabInventory` reads a missing value as
false), and roles added later (member servers) opt in the same way. `site.yaml
tailscale.enabled` still switches it off for the whole site. A DC gets no auth key in its
build secrets, no install, no policy and no watchdog; `TS-001` passes on it as "not used
by this role".

**Getting to a DC** is Tailscale to MGMT, then Remote Desktop from MGMT: DCs allow Remote
Desktop from the lab subnet already (above), so no firewall change. Or the Proxmox
console, as before.

**The DNS safeguards stay, for now.** The single-homing, the Tailscale record cleanup in
the rotation and `DNS-005` are harmless with one adapter, and still catch leftovers from
DCs built before 1.8 (and would protect a DC again if lab.yaml ever turned Tailscale on
for DCs). They can go in a later release, once no DC with Tailscale is left.

**Retiring a DC logs it out of the tailnet before demoting it.** The demotion runs with
`-NoRebootOnCompletion`, and until the restart that follows the machine accepts neither
the domain accounts nor the new local Administrator password, so a logout after it was
refused and every retired DC stayed in the device list. The rotation (Retire, and Abort
for the replacement) now logs out first, while the domain credentials still work: the
AuthKey policy and the watchdog go first, so it doesn't log back in, and MGMT reaches the
DC over the lab network, so nothing after it needs the tailnet. Devices left behind by
earlier retirements are removed by hand in the Tailscale admin console.

What follows is how a machine joins, which is now MGMT (and the DC parts for DCs built
before 1.8).

**The key is a secret, so it lives in the vault**, not in `site.yaml`: `site.yaml` is in
git and in every handover and zip. It reaches each guest with the other build secrets and
is deleted when bootstrap ends. Use a reusable, tagged, non-ephemeral key (ephemeral
devices drop off when a lab is shut down for a while, and don't come back by themselves).

**Never the lab's DNS, never the lab's routes.** `--accept-dns=false`, or the tailnet's
DNS settings can replace a domain member's DNS and break AD; `--accept-routes=false`, or
the lab's own subnet route would pull lab traffic through the tailnet.

**DCs stay single-homed as far as AD is concerned** (DCs built before 1.8). A DC registers every address it has
in AD's DNS (its host name, the domain name, gc, the partition names), and members would
then try to reach it on its Tailscale address. So, before the adapter gets an address:
the adapter doesn't register in DNS, the DNS server publishes only the lab address in its
own records (it still listens on every address: restricting it failed on the first real
run, and would cut off the DC's own loopback lookups), and Netlogon skips the domain-name and gc A records
(`DnsAvoidRegisterRecords LdapIpAddress GcIpAddress`), which the DC creates for its lab
address itself as static records (the rotation's DNS cleanup removes them with the DC).
Any Tailscale address that still appears is removed, and `DNS-005` checks for them.

**Remote Desktop on the Tailscale adapter only.** Packets on that adapter can only come from
the tailnet, so this doesn't open `100.64.0.0/10` from anywhere else; Tailscale's access
rules decide which tailnet devices may connect. WinRM stays MGMT-only on the lab network.

**The key stays on each machine, in Tailscale's AuthKey policy.** On Windows, a login made
with `tailscale up --authkey --unattended` doesn't reliably survive a restart (a known,
open Tailscale issue: the first DCs came back as "Needs authentication"). With the `AuthKey`
system policy (`HKLM\SOFTWARE\Policies\Tailscale`), the service logs itself back in
whenever it needs to. The trade-off is a reusable key at rest on each machine that joins
(since 1.8, MGMT only); the
policy key is readable by SYSTEM and Administrators only, which on Tier 0 machines are the
people who could add devices anyway. Limit what the key can do in Tailscale: tag it, and
let the tag's access rules allow only what the lab needs (Remote Desktop in). The same
policies fix `UnattendedMode`, `UseTailscaleDNSSettings` and `UseTailscaleSubnets`, so
nothing, the tray app included, can switch DNS or routes back on. Retiring a machine
removes the AuthKey policy before logging out.

**And a watchdog, because the policy wasn't enough.** After the next round of Windows
updates and restarts, DCs and MGMT were logged out anyway. So every machine also gets a
SYSTEM task, `MidCoastLab-Tailscale`, at start-up and every 15 minutes: if `tailscale
status` says it isn't logged in, it runs `tailscale up` with the key (DPAPI-encrypted for
the machine, in a folder only SYSTEM and Administrators can read) and the lab's flags. It
logs to `C:\ProgramData\MidCoastLab\Tailscale\watchdog.log`. Deterministic, and it doesn't
depend on how a given Tailscale version treats unattended logins. Retiring a machine
removes it first.

**Best-effort.** The lab works without the tailnet, so a failed join (an expired key, no
internet) is a warning (`TS-001`), not a failed build.

## Terraform guard: deletes must be named

Until v1.4 the guard refused deletes of instances the ledger called active. That trusted
the ledger: an emptied or damaged `instances.yaml` would make every VM look unprotected,
and a plan to destroy the DCs would pass. Now every apply names what it expects to
destroy (`-AllowDelete`: the retiring MGMT, the retiring DC, an aborted replacement), and
any other delete, any replace, or a delete of the machine running the pipeline refuses the
whole plan.

## Release names and the compatibility number

The lab ships changes several times a day, so a hand-bumped `1.4` can't tell one build
from the next. Every merged change is now a **release**, `LAB-<YYMMDD>-<NN>` (the same
shape as machine and template names), tagged in git and recorded on every machine and
template it builds. `version` stays, but only as a **compatibility** number: it moves when
an existing lab has to do something beyond `git pull` (minor: rebuild templates or replace
machines to get it; major: change `site.yaml`). A date can't carry that signal, and the
next person updating a lab needs exactly that signal.

## MGMT-00 setup scripts (v1.5)

The first build had four places where the runbook said "do this by hand" on MGMT-00:
putting the repo in place and making it a git repository, creating the KeePass database,
the domain join with its DNS change, and the post-join grants (folder ACL, git
`safe.directory`, Remote Desktop group). Each is now a script under `setup/mgmt/`, so the
hand-built MGMT-00 gets exactly what a pipeline-built MGMT gets, from the same
`Lab.System` functions (`Enable-LabRemoteDesktop`, `Grant-LabRemoteDesktopGroup`,
`Set-LabMgmtFolderAcl`, `Add-LabGitSafeDirectory`), and the runbook is paste-and-run.

**Git identity comes from `site.yaml`, not a new setting.** Commits need a name and
e-mail on every account on every MGMT (each replacement is a new profile). Rather than
another site value (which would have made this a major version), `Set-LabGitIdentity`
derives them from the administrator in `site.yaml` whose username matches the signed-in
account (`-a` suffix stripped), else the first tier 0 administrator: `given_name surname`
and `<username>@<tenant domain>`, their UPN. It never overwrites a value someone set
themselves. `Initialize-LabVault` (run once per account per MGMT anyway) and MGMT rotation
`Complete` call it.

**The domain join uses WMI's `JoinDomainOrWorkgroup`**, because `Add-Computer` doesn't
exist in PowerShell 7 and the rest of the setup lives there. The post-join grants need
the domain to resolve the Tier 0 group, so they run as a one-shot SYSTEM task at the next
start-up (`MidCoastLab-PostJoin`), the same point in time at which a pipeline-built MGMT
gets them (its `Finalize` stage, after the join's reboot).

**The vault is created by `keepassxc-cli db-create`**, which ships with KeePassXC, so step
6 is one command and the master password is asked for twice, as the GUI would.

**A locked vault asks instead of failing.** `Get-LabSecretText` calls `Unlock-LabVault`
once when a read fails, so a new window never needs a separate `Unlock-SecretVault`;
non-interactive sessions still get the old error with the command to run.

## MGMT-00 on the tailnet from the start (v1.5)

With `tailscale.enabled`, `proxmox-setup.sh` can put MGMT-00 on the tailnet during its
unattended install, so it's reachable before the vault, and the reusable key in it, exist.
The key for that is **one-time** (reusable off, tagged, ephemeral off), typed at the
prompt or taken from `TAILSCALE_AUTHKEY`, never written to the site kit: it rides on the
answer CD (root-only, shredded after the install), the guest reads it from the CD and never
copies it to disk, and Tailscale consumes it on first use. Step 6 (`Join-LabTailnet.ps1`)
then re-authenticates MGMT-00 with the vault's reusable key and adds the policy and
watchdog, so from there it is like every other lab machine. Skipping the prompt changes
nothing: step 6 joins it then.

## Templates by inventory key (v1.5)

`Build-LabTemplate -Template` is checked against the keys under `templates:` in
`lab.yaml` instead of a fixed list, and every "build it first" message names the key for
the family it needs (`Get-LabTemplateKey`). Adding a template (Server Core, another
edition) is then an inventory change plus a Packer definition, with no script edits, and
the runbook spells out `-Template windows_server_2022` for the same reason.

## Script reference (v1.5)

`docs/scripts.md` lists every script, its parameters, where it runs and when. It is
generated from the scripts' own comment-based help by `tools/New-LabScriptReference.ps1`,
so the help in the script is the one place to keep up to date; the generator runs before
a release and refuses a script with no synopsis.

## Several labs on one cluster (1.6)

"One lab per Proxmox cluster" came from four cluster-wide names fixed in the product:
the pool `MidCoast-Lab`, the user `terraform-prov@pve`, the role `MidCoastProvisioner`
and the tag `midcoast-lab`. Sites were already separated by network (a /24 of their own
behind OPNsense or an SDN VNet) and by VMID block; only the names stopped a second lab.

**The names are now inventory.** `lab.yaml` keeps the four as defaults, `proxmox.pool`,
`proxmox.role`, `proxmox.tag` and `proxmox.service_account.user`; `site.yaml` may set any
of them, and `{site}` in a value becomes the site slug (`site.name`, lower case,
`[a-z0-9-]`, 24 characters at most). The resolved inventory carries the final names, so
Terraform, Packer, the orchestration, the site kit and CERT all read one place.

**Defaults stay the pre-1.6 names; the template ships per-site ones.** A site built before
1.6 has no override in its `site.yaml` and keeps `MidCoast-Lab` and friends, so nothing on
its cluster has to be renamed or recreated and `git pull` is enough (minor version).
`site.template.yaml` and `site.example.yaml` set `MidCoast-Lab-{site}` and so on, so every
new site gets its own names without thinking about it. Deriving the defaults from
`site.name` instead would have changed every existing lab's names on upgrade: a major
version for the sake of a line in the template.

**Ownership is checked, not assumed.** The pool's and user's comments name the site that
created them; `proxmox-setup.sh check` and `Test-LabSite.ps1` refuse a pool or user that
belongs to another site. A VM in this lab's VMID block that carries another lab's tag
(`midcoast-lab*`, but not ours) is reported as an overlapping block, not as a stray VM.
Ownership checks everywhere (`Test-LabSite`, `Remove-LabUnusedTemplates`,
`Build-LabTemplate`, teardown) use the site's own tag, so one lab never counts another's
VMs as its own.

**Teardown takes the names from the runbook.** `proxmox-teardown.sh` keeps the pre-1.6
names as defaults and accepts `--pool --user --role --tag`; the site kit's `RUNBOOK.md`
("Starting over") prints the full command for the site, so it can never remove another
site's pool by default.

## Shared templates (1.7)

Several labs on one node each built their own Server 2022 and Windows 11 templates: an
hour and 15–25 GB each, rebuilt monthly, for the same image (issue #25). Two things tied a
template to its lab, and 1.7 removes both.

**Templates are site-neutral.** At build time the WinRM/ping firewall rule trusted the
building lab's two MGMT *addresses*, so a clone at another lab refused its own MGMT. The
template now carries the MGMT slots' *host numbers* (`servers[MGMT].slots[*].host`, product
constants), and `Initialize-LabRemoting.ps1` puts them in the subnet of the DHCP address
the clone gets on first boot: the lab's own /24, wherever it was cloned. `MGMT-005` checks
the resulting rule, not how it was made, so it is unchanged. Versions built this way are
tagged `site-neutral`; only those can serve another lab.

**Templates have no NIC.** Proxmox checks `SDN.Use` on the *source* VM's bridges when it
clones (checked in PVE 9.2's `clone_vm`), so a template on the owner's bridge could only be
cloned by a lab allowed onto the owner's network. `Build-LabTemplate.ps1` removes `net0`
from each new version instead; Terraform gives every clone its NIC on its own lab's bridge
(`network_device`), as it always did. Requirement this adds: the lab
bridge's DHCP scope is inside the lab subnet (it always was in practice: `Test-LabSite`'s
advice is to exclude the static range from it).

**The local Administrator password stays the owner's until first contact.** The issue
thought everything else in a template was already neutral, but the template also carries
its builder's local Administrator password (`unattend-midcoast.xml`), and the orchestrator's
first connection uses the site's own. A borrowing site keeps the owner's password in its
vault (`MidCoast-TemplateAdministrator`, asked for by `Initialize-LabVault.ps1`);
`Deploy-LabInstance` tries it after the site's own and, on a fresh clone, sets the site's
password before pushing anything. So every machine ends up with its own lab's password,
the owner's is used once per clone, and nothing new goes in Proxmox (a password on the
config drive would sit in the VM's configuration, readable with `VM.Audit`).

**One owner, many borrowers.** A site either builds templates (the default) or borrows
them with `site.yaml templates.shared_from.vmid_base`, the owner's `vmid_base`:

- The borrower's current version per family is the **newest site-neutral template in the
  owner's range**, by name (`<family>-<YYMMDD>-<NN>`). The owner's ledger isn't readable
  from another site; names are, and the owner deletes superseded versions once unused.
- `proxmox-setup.sh` of the borrower grants its user a small role, `MidCoastTemplateUser`
  (`VM.Audit`, `VM.Clone`), on `/vms/<id>` for each of the owner's 48 template VMIDs. ACLs
  can exist before the VM does, so later versions are covered. The owner isn't involved.
  Each run also removes this user's grants outside the current range, so changing or
  dropping `shared_from` takes the old rights back (otherwise they'd carry over to
  whichever lab took that VMID block next); removing the borrower's user removes them all.
- Instances still pin `template_vmid` at allocation, so rotation works as before. A
  borrowed pin also records `template_owner` (the owner's `vmid_base`), and validation
  checks the pin against that owner's range, not against today's `site.yaml`: a site can
  stop borrowing, or borrow from another lab, and its machines move over at rotation.
- `Build-LabTemplate.ps1` refuses on a borrower. The borrower's own +100..+149 stay
  reserved, so it can go back to building later.
- Linked clones live on their template's storage, so the borrower's
  `proxmox.storage.templates` must be the owner's (checked by both pre-flights).
- **Owner safety.** Proxmox can't delete a template that has linked clones, so the
  owner's `Remove-LabUnusedTemplates` keeps such versions (and says another lab may use
  them; a borrower's machines on old versions can fill the owner's 24-ID range until the
  borrower rotates them, and the owner's "no free VMID" error says so), and `proxmox-teardown.sh` of an owner keeps the templates other labs' VMs are
  cloned from, with the pool that holds them, and says which VMs use them. The issue
  suggested a `--force-templates` override; it can't work, so there isn't one. A
  borrower's teardown only ever acts inside its own block.

**A new lab is told when it could borrow.** `proxmox-setup.sh check` runs as root and sees
every lab, so it lists other labs' site-neutral templates on the node and prints the
`shared_from` line that would use them. `Test-LabSite.ps1` (the lab's token sees only its
own pool) warns a building site that has no template yet and points to that check.

**Not done (issue #25, part C):** a template-only "factory" site that owns the templates so
that no lab's teardown can threaten them. Any lab can be the owner today; a factory is
the same thing without servers, and can follow if owners turn out to churn.

## The site folder: a site's files outside the product (LAB-261128-00)

`site.yaml` and the ledger used to sit in `inventory/`, next to the product, and every
site committed them in its copy of the product repo. That works for one lab, but the
product is shared: anyone who changes it and pushes from that copy can publish their
site by mistake (it happened once, LAB-261106), and a product kept clean only by
exporting it from a private copy can't take changes from more than one maintainer.

So a site's files live in a **site folder**, `site/`: `site.yaml`, the ledger
`instances.yaml` and, optionally, `deny.txt` (the site's private patterns). The product
ignores the folder, and it is a git repository of its own, so the product repo never
holds a site and the ledger's history (the build history) stays with the site.

- **How the tools find it** (`Get-LabSiteDirectory`, Lab.Inventory): `MIDCOAST_LAB_SITE`
  if set (a workstation keeping its site elsewhere), else `site/`, else the old
  `inventory/` layout, with a warning. Both `site/site.yaml` and `inventory/site.yaml`
  is an error: two copies would drift. The ledger is always next to `site.yaml`.
- **On MGMT only `site\` counts** (`MIDCOAST_LAB_SITE` is refused for the repo at
  `handover.repo_path`): the handover copies the repo folder, so a site inside it travels
  with it, `.git` included, and the handover checks both histories and the ledger arrived.
- **Not a git submodule**: the product would record a private URL and commit IDs.
- **Terraform gets both paths** (`-var=ledger_path`, `-var=inventory_path`) on every plan
  and apply, so `variables.tf`'s defaults never decide which ledger is read.
- **Leaks are caught before a push**, not after: `tools/Test-LabPublicTree.ps1` refuses
  site files, secrets and deny-list matches in the commits being pushed, and
  `tools/Install-LabGitHooks.ps1` makes it a pre-push hook with the site's own
  `deny.txt`. Once a branch is on GitHub it is public, so this is the only check that can
  stop a leak; the deny list exists only on the site's side, since publishing the
  patterns would publish what they protect.
- **The old layout still works**, so existing labs take this release with nothing to do
  and move when convenient.

## Known gaps

- **Windows DHCP failover isn't in scope**, since the router serves DHCP. Make sure the
  router's pool excludes `10.50.10.10–49`.
- **Windows 11 evaluations last 90 days**, half the DCs' 180. Plan on rotating MGMT about
  every two months; `EVAL-001` warns when fewer than 30 days remain.
- **Templates carry the MGMT slots' host numbers** from the inventory they were built
  with (1.7: host numbers, no longer addresses). If `servers[MGMT].slots` changes, rebuild
  the templates, then rotate. Templates are per node unless storage is shared (Ceph RBD);
  sharing between nodes or clusters isn't in scope.
- **Rotation of DCs**: built in v1.4 (see 'DC rotation').
- **MGMT-00's one-time Tailscale join has no watchdog** until step 6 switches it to the
  reusable key; a restart in between may log it out. MGMT-00 lives hours, so that's accepted.
