# Changelog

Two numbers, in `inventory/lab.yaml`:

- **`release`**: `LAB-<YYMMDD>-<NN>`, like the lab's machine and template names. Every
  merged change is a new release, with its own section here and a git tag of the same
  name. Each machine and template records the release (and commit) that built it.
- **`version`**: the **compatibility** number. It changes rarely, and says what an
  existing lab must do to take a release:
  - **major** (`2.0`): `site.yaml` must change (a new required value, or a changed meaning).
    `Test-LabInventory` says what's missing.
  - **minor** (`1.5`): the lab gains or changes a capability that an existing lab only gets
    by **rebuilding templates or replacing machines**: a new role or phase, a change baked
    into templates or into how machines are built, or a new optional `site.yaml` setting.
  - **neither**: everything else (fixes, docs, scripts). `git pull` and the next run is all
    it takes.

Every release section starts with what it needs: *nothing*, *rebuild templates*, *rotate
DCs / MGMT*, or *site.yaml change*. Details and reasons: [docs/decisions.md](docs/decisions.md).

## LAB-261123-01 (compatibility 1.6): get a release

Needs: nothing.

Docs: the README and the runbook point to the latest release on GitHub for a tested
version (`master` can be ahead of it): its zip, or a clone with a branch of your own at
the release's tag, so the ledger's commits have a branch to go on.

## LAB-261123-00 (compatibility 1.6): REPL-001 reads each link's own state

Needs: nothing (`git pull`). Existing DCs get the new check at their next rotation.

Fixed:
- `REPL-001` (no replication failures) reads each inbound link's failure count from
  `repadmin /showrepl /csv`, for every naming context, the DNS application partitions
  included. It used `Get-ADReplicationFailure`, which reads the KCC's in-memory failure
  cache. A successful replication doesn't clear that cache, so a DC rolled back to a
  snapshot that includes RAM (as CERT takes them) kept failing `REPL-001`, and CERT's
  pre-flight refused to start, for a failure from before the snapshot. Restarting
  Active Directory Domain Services on the DC clears the old cache.

## LAB-261122-00 (compatibility 1.6): ignore password notes

Needs: nothing (`git pull`).

Fixed:
- `.gitignore` covers `passwords` and `passwords.*`. `Initialize-LabRepo.ps1` commits
  everything in the folder that isn't ignored, so a note of the secrets that
  `proxmox-setup.sh` prints, saved beside the repo's files, went into git. Other file
  names are still committed: keep such notes outside the folder. A file that is already
  tracked stays tracked until `git rm --cached <file>`.

## LAB-261121-00 (compatibility 1.6): several labs per cluster, CERT, fixes from the v1.5 build

Needs: **re-run the site kit's `proxmox-setup.sh`** on the node (role update only: it adds
two privileges to the provisioning role and a site comment to the user; nothing is
recreated), then `git pull`. No `site.yaml` change: a site built before 1.6 keeps its
Proxmox names. Minor version because the templates' tag and the lab's names on the
cluster are now inventory values, and a new optional `site.yaml` setting exists.
Closes #19, #20, #21, #22, #23, #24.

**Public repo clean-up.** `inventory/site.yaml` (a real site's), `.obsidian/` and
`Untitled.base` were committed to `master` on 2026-11-06 by mistake and are removed;
editor clutter is gitignored. If your clone predates this release, `git pull` removes
them. They are also rewritten out of the history of the public repo, so a clone made
before this release needs `git fetch` and a reset onto the new `master` rather than a
plain pull.

Added:
- **Several labs on one cluster** (#24). The pool, provisioning role, VM tag and
  provisioning user are inventory values: `lab.yaml` keeps the pre-1.6 names
  (`MidCoast-Lab`, `MidCoastProvisioner`, `midcoast-lab`, `terraform-prov@pve`) as
  defaults, and `site.yaml` may set `proxmox.pool`, `proxmox.role`, `proxmox.tag` and
  `proxmox.service_account.user`, with `{site}` standing for the site slug (`site.name`,
  lower case, `[a-z0-9-]`). `site.template.yaml` and `site.example.yaml` ship
  `MidCoast-Lab-{site}` and friends, so every new site gets its own names. Each lab still
  needs its own network segment and VMID block. `proxmox-setup.sh check` and
  `Test-LabSite.ps1` refuse a pool or user another site created (its comment names the
  site) and report a VM of another lab inside this block as an overlapping VMID block;
  every ownership check uses the site's tag. `proxmox-teardown.sh` takes
  `--pool --user --role --tag` (the runbook's "Starting over" prints them for your site).
  Validation checks the resolved names against what Proxmox accepts. NEW-SITE.md,
  decisions.md and architecture.md no longer say "one lab per cluster".
- **Snapshots for CERT** (#23). The provisioning role gains `VM.Snapshot` and
  `VM.Snapshot.Rollback`, so CERT (the break/fix scenario runner) can snapshot and roll
  back the lab's VMs with the lab's own token. While a CERT scenario is active
  (`C:\MidCoastLab\CERT.lock`, `handover.cert_lock_path` in `lab.yaml`), `Invoke-LabPhase`,
  both rotations, `Build-LabTemplate` and every Terraform apply refuse to run, the same
  way they do for `HANDOVER.lock`: a rotation inside a scenario would be undone by the
  rollback and leave the ledger describing machines that no longer exist.
- **`orchestration/Reset-LabLedger.ps1`** (#20). After `proxmox-teardown.sh`, the ledger
  in the repo and the Terraform state still describe the old lab, and Phase 1 said
  *already deployed*. The script empties `instances:`, drops template versions that are
  gone from Proxmox, removes the Terraform state and the lock files, and commits. It
  refuses while any listed VM still exists, so it can't reset a live lab. `Test-LabSite`
  now reports an active instance or current template that is missing from Proxmox as an
  error pointing at it; `Invoke-LabPhase -Phase 1` checks the active DCs exist before
  saying "already deployed"; the teardown prints the reminder; runbook "Starting over"
  has the step.

Changed:
- **`Initialize-LabVault.ps1`** (#19): the password rules are printed before the prompt;
  a wrong master password is asked again (three tries) and nothing is written until the
  vault really opens (before, every `Set-Secret` "succeeded" against a locked vault and
  stored nothing); the passwords of your own `<username>` and `<username>-a` accounts can
  be chosen (12+ characters, three classes) or generated, asked once per run;
  `-GeneratePasswords` skips the question. A database created in the same run is
  unlocked with the password you just chose, not asked again.
- **git `core.filemode=false`** on the repo (#22): set by `Initialize-LabRepo.ps1` and by
  the MGMT handover (`Set-LabGitRepoConfig` in `Lab.System`), since a clone copied from
  Linux keeps `core.filemode=true` and every `.sh` file then shows as modified on Windows
  and blocks merges. `Test-LabSite.ps1` warns when it's still true.
- Runbook (#21): step 4 says to wait for Windows Update to finish before the toolchain,
  with a PowerShell check for "still installing / restart pending"; step 5 says to wait
  for the RSAT lines before moving on.

Docs: `docs/scripts.md` regenerated (new script and parameters).

## LAB-261105-04 (compatibility 1.5): MGMT-00 by script, scripts reference

Needs: nothing for a running lab (`git pull`); the next DC or MGMT rotation carries the
shared role code, and no template rebuild or `site.yaml` change is needed. Minor version
because how MGMT-00 is built changed (an optional tailnet join during its install) and the
first-build steps are now scripts. Closes issues #3–#17.

Runbook (`docs/runbook.md`, was `docs/mgmt-00.md`, #17), now paste-and-run on MGMT-00:
- **Step 5** names the folder first and uses two scripts (#5, #6, #7, #11):
  `Install-MgmtTools.ps1` (elevated; `Set-ExecutionPolicy ... -Force`, so no prompt) then
  new **`Initialize-LabRepo.ps1`**, which copies the repo to `C:\MidCoastLab\repo`, makes it a
  git repository when it isn't one (no remote needed), sets the git identity and validates.
  `Install-MgmtTools` ends by naming the next command.
- **Git identity comes from `site.yaml`** (#13): `Set-LabGitIdentity` derives name and
  e-mail from your administrator entry (`<username>@<tenant domain>`), on every account
  and every MGMT; `Initialize-LabVault` and MGMT rotation `Complete` apply it. The
  `git config --global` lines are gone from every guide.
- **Step 6**: `Initialize-LabVault.ps1` creates the `.kdbx` itself with `keepassxc-cli`
  (#8); the vault no longer has to be made in the GUI first.
- **Step 8 is one script** (#12, #15): new **`Join-LabDomain.ps1`** points DNS at the
  active DCs, joins the domain with `svc-domainjoin`, schedules the post-join rules
  (Remote Desktop for the Tier 0 group, git `safe.directory`, the `C:\MidCoastLab` ACL) as a
  one-shot SYSTEM task for the next start-up, and restarts. The "register the vault"
  step is a code block.
- **Step 9 and `Invoke-LabMgmtRotation -Stage Prepare` say the same thing** (#14):
  `Complete -KeepOld` first, `Complete` to destroy. The guides and every script's closing
  "commit the ledger" line use one wording (`Write-LabCommitHint`).
- **Step 7 spells out `-Template windows_server_2022`** (#10); `Build-LabTemplate -Template`
  is validated against `lab.yaml`'s template keys instead of a fixed list, and every
  "build it first" message names the right key (`Get-LabTemplateKey`).
- **"Starting over"** (the teardown commands, with your VMID block filled in) moved from
  the README to the end of the runbook (#3).

Added:
- **MGMT-00 on the tailnet during its install** (#4): with `tailscale.enabled`,
  `proxmox-setup.sh` asks for a **one-time** auth key (or takes `TAILSCALE_AUTHKEY`),
  puts it on the root-only answer CD, and MGMT-00 joins at first logon; the CD is shredded
  afterwards and the key never enters the site kit. Step 6 (`Join-LabTailnet.ps1`) then
  switches it to the vault's reusable key with the policy and watchdog. Enter nothing to
  skip.
- **`docs/scripts.md`** (#16): every script, its parameters and switches, where it runs,
  generated from the scripts' own help by `tools/New-LabScriptReference.ps1`;
  `Export-LabRelease` refuses to export while it's stale (`-Check`).
- **A locked vault asks for its password** (#9) instead of failing: `Get-LabSecretText`
  prompts once per run. Every guide says so; `Unlock-SecretVault` is optional.

Changed, code (one implementation each, shared by the hand-build and the pipeline):
- `Lab.System`: `Enable-LabRemoteDesktop`, `Test-LabRemoteDesktop`,
  `Grant-LabRemoteDesktopGroup`, `Set-LabMgmtFolderAcl`, `Add-LabGitSafeDirectory`,
  `Join-LabTailnet` replace the copies in `dc.ps1`, `mgmt.ps1`, the validations and the
  handover. `Lab.Validation`: `Invoke-LabCommonChecks` (NET, TS, MEM, EVAL) replaces the
  copies in both validation scripts. Behaviour is unchanged.
- `Build-LabTemplate` uses `Get-LabPveToken -Purpose packer`; the handover zip path comes
  from inventory; an unused variable and a stray section in `Invoke-LabPhase` and
  `Test-LabInventory` are gone; the Packer scripts have comment-based help; the catalog's
  recovery notes name the current rotation commands.

## LAB-261105-03 (compatibility 1.4): README and NEW-SITE reorganised

Needs: nothing (`git pull`). Documentation only; no script changes.

- `README.md` is now read first, act last: what the lab is, how the documents fit
  together, **a lab's lifecycle** (prepare, first build, run, update, start over; this
  replaces "Status", "What Phase 1 does" and "Keeping in step"), requirements and reference
  sections, then one **checklist** at the end: get the repo (clone or download), unblock
  it, install `powershell-yaml`, fill in `site.yaml`, check it, generate the site kit, and
  follow `RUNBOOK.md`. Git is needed only on MGMT, not on your workstation.
- `docs/NEW-SITE.md` is now only what to collect for `site.yaml`, where to find each
  value, how to fill it in, and what the checks' complaints mean. The Git setup, the site
  kit and the runbook summary moved to the README checklist and the runbook.
- New `docs/replace-mgmt.md` and `docs/replace-dc.md`, moved from the README's "Replacing
  MGMT" and "Replacing a DC" (with `git push` after each ledger commit).
- `docs/mgmt-00.md` and `inventory/site.template.yaml` point to the new places.

## LAB-261105-02 (compatibility 1.4): tear a site down

Needs: nothing (`git pull`).

- `setup/proxmox/proxmox-teardown.sh`: removes a site from Proxmox so it can be built again
  from scratch, keeping the ISOs. Shows the plan first (`--dry-run` stops there) and asks
  you to type DESTROY. It removes only the lab's own VMs in its VMID block (tagged
  `midcoast-lab`, or in the pool; anything else there is listed and skipped), clones
  before templates, leftover disks in that block, the pool, the provisioning user and its
  tokens, the role, MGMT-00's answer CD and any leftover secrets file; with
  `--include-backups`, the block's vzdump backups.

## LAB-261105-01 (compatibility 1.4): ready to publish

Needs: nothing (`git pull`).

- MIT licence (`LICENSE`) and `SECURITY.md`.
- `inventory/site.example.yaml`: the filled-in example site (`example.com`), separate from
  your own `site.yaml`. The public repo ships no `site.yaml`, so pulling a release never
  touches yours.
- `tools/Export-LabRelease.ps1`: exports a release (no `site.yaml`, an empty ledger, no
  Terraform lock file) for the public repo, and refuses if anything in it matches this
  site's private patterns (`tools/release-deny.txt`, never exported) or looks like a secret.
- README: what the lab is (and isn't), how to get it, licence. NEW-SITE: starting from a
  clone, keeping the public repo as `upstream`, and pulling releases.

## LAB-261105-00 (compatibility 1.4): release names

Needs: nothing (`git pull`).

The first release under release names. Everything in v1.4 below, as built and run on the
first real site (two DCs, a pipeline-built MGMT, Tailscale), plus:
- `lab.yaml` has `release:`. Machines record it in their metadata (`platform_version`, e.g.
  `LAB-261105-00 (7598827)`), templates in their Proxmox description.
- `Test-LabInventory` checks the release name's format.

## v1.4 (Nov 2026, before release names): fixes from the first real build

Everything found while building the first real site end to end. No site has to change
`site.yaml`, so this is a minor version; set the lab's DHCP server to authoritative.

Added:
- **Tailscale on every lab machine** (optional: `site.yaml` `tailscale.enabled: true`; the
  auth key in the vault as `MidCoast-Tailscale-AuthKey`, asked for by Initialize-LabVault).
  DCs and MGMT join at the end of their setup with `--unattended --accept-routes=false
  --accept-dns=false`; the Tailscale adapter never registers in DNS; Remote Desktop is
  allowed on that adapter only. DCs first limit the DNS records they publish and Netlogon to the lab
  address and register the domain and gc A records for it themselves, so no Tailscale
  address reaches AD's DNS (`DNS-005`). MGMT-00 joins with `setup/mgmt/Join-LabTailnet.ps1`.
  Retiring a DC or MGMT logs it out of the tailnet first. A failed join is a warning
  (`TS-001`), never a failed build. Optional, so still a minor version. The key must be
  reusable, tagged and not ephemeral; every guide and the vault prompt say so. Each
  machine also gets Tailscale's system policies (AuthKey, unattended, no DNS, no routes,
  readable by SYSTEM and Administrators only), because a CLI login didn't survive a
  restart on the first DCs. And a watchdog (scheduled task `MidCoastLab-Tailscale`, at
  start-up and every 15 minutes) logs a machine back in whenever updates or restarts have
  logged it out; `platform/tailscale/Enable-LabTailscaleWatchdog.ps1` adds it to existing
  machines.
- **MGMT-00 installs unattended.** `proxmox-setup.sh` builds an answer CD on the node and
  starts the install: disk and VirtIO drivers, no first-run screens (licence, privacy,
  account), a local admin `LabAdmin` with a generated password, then guest tools, name,
  time zone, static address and Remote Desktop. It waits, ejects the media and deletes
  the answer CD. Every secret it creates (API tokens, the local password) is printed at
  the end, from a root-only file you shred afterwards. Runbook steps 3 and 4 shrink to
  "run it, then sign in".
- **DC rotation**: `orchestration/Invoke-LabDcRotation.ps1 -Stage Add | Retire | Abort`
  replaces a DC with a new replica from the current template: FSMO roles and the PDC's time
  source move, every DNS client in the lab is repointed, then the old DC is demoted, its
  DNS leftovers and computer object removed and its VM destroyed. `-Force` seizes roles
  and cleans up a DC that can't be reached.

Changed (product):
- **OU `Users` → `People`**, with `placement.standard_users`. A top-level OU can't share a
  name with the built-in `CN=Users`; validation now rejects built-in container names.
- **MGMT Remote Desktop** is granted explicitly to the Tier 0 group only.
- **MGMT Remote Desktop sources**: new optional `site.yaml` setting
  `network.remote_desktop_from` (e.g. your workstation's LAN) adds networks to the lab
  subnet. Optional, so still a minor version.
- **DC Remote Desktop**: every new DC turns it on for the lab subnet (NLA on); new
  validation `RDP-001` (High). Existing DCs get it at their next rotation.
- **DCs** also get the DFS management tools (`dfsrdiag`).
- **MGMT RSAT is configurable** (`rsat:` on the MGMT role). The default, `standard`, is
  what the lab uses: AD DS/LDS, DNS, Group Policy and Server Manager (was the first three).
  Add capability names for more; `all` installs every RSAT tool, which took over 3 hours
  per MGMT on the first build, so it isn't the default.

Fixed, pipeline:
- **Guest identity.** Two clones shared a DHCP address and a DC's setup went to the wrong
  VM. Sessions are now accepted only from the guest with the VM's MAC (from Proxmox), the
  VM's current address comes from its guest agent, and a guest already set up as another
  instance is refused. Root cause: the template kept the build VM's DHCP lease; it is now
  cleared before sysprep (and the runbook asks for an authoritative DHCP server).
- Proxmox API calls skip .NET's header validation (`PVEAPIToken=` was rejected before any
  request) and never print token secrets.
- Runbook step 5 sets up git on MGMT-00 (a copied repo has no `.git`), and the site
  pre-flight stops if the repo isn't a git repository.
- Site pre-flight: ISO names compared case-sensitively, as Proxmox does; only live
  (`Reachable`) ARP entries count as an address in use.
- DC finalize: the DFSR poll is best-effort, and it waits for replication and Group Policy
  queries to answer before validation (a new DC failed REPL-001 with credential errors and
  passed on -Retry).
- Retiring a machine removes its AAAA records too, and DC Retire removes any Tailscale
  address left under the domain, gc and partition names.
- `REPL-002` counts a partner as stale after 3 hours without a successful replication (was 1):
  a quiet domain replicates hourly, so an hour was a false alarm waiting to happen.
- Bootstrap may take up to 6 hours before the orchestrator gives up (was 2), and the
  guest task up to 8 (was 4): a MGMT installing every RSAT tool took over 3 hours.
- MGMT handover: the lock-down left every handed-over file with an empty ACL (unreadable,
  even elevated). The protected ACL now goes on `C:\MidCoastLab` only, everything below is
  reset to inherit it, and the handover checks a repo file grants the lab group.
- MGMT Remote Desktop: turned on through the Terminal Services provider, TermService set to
  automatic and started, firewall rules found by group (a miss is an error, not silence).
  New validation `MGMT-007` (Critical): RDP on, listening on 3389, firewall rule enabled.
- The bootstrap task's settings lost `-StartWhenAvailable -MultipleInstances IgnoreNew` to a
  misplaced comment in an earlier v1.4 change; restored.
- The orchestrator never tries a guest's Tailscale address for WinRM (guests allow it from
  MGMT's lab addresses only).
- Windows 11 guests: every orchestrator session allows scripts for that session (client
  editions default to `Restricted`), and pipeline-built MGMTs are set to `RemoteSigned`.

Fixed, templates:
- Windows 11 clones no longer stop at OOBE's "Who's going to use this device?": the clone
  answer file creates a local account, `MidCoastSetup`, which bootstrap deletes at its first
  stage (enabling the built-in Administrator, the first attempt, wasn't enough). Needs a
  Windows 11 template rebuilt from this version.
- Windows 11 build: registry keys are created only when missing (`New-Item -Force` failed
  on `Control\BitLocker` and stopped the build before WinRM came up); client tweaks can no
  longer stop a build.
- Finalize removes per-user Appx packages on Server too (Edge), stops Edge's updater and
  retries sysprep, naming the blocking package.

Fixed, MGMT toolchain and setup:
- Installs the Visual C++ runtime (KeePassXC needs it), handles KeePassXC's renamed MSI,
  initialises a fresh PSResourceGet store, and reports RSAT pending a restart.
- `proxmox-setup.sh` keeps API token comments consistent.
- `.gitattributes` keeps shell scripts LF.

Docs:
- Reading order (README → NEW-SITE → generated RUNBOOK); NEW-SITE covers installing Git
  (with or without winget), unblocking files from a zip, and placeholders.
- Runbook spelled out: ISO names and download links (step 2), and domain join with the
  vault password, DNS, Remote Desktop and a way back in (step 8).
- First-build order: both templates are built before Phase 1 (step 7), and the runbook
  ends by replacing MGMT-00 with a pipeline-built MGMT (step 9), so MGMT-00 lives hours,
  not weeks.

- **Terraform guard**: an apply may delete only the VMs the run names (`-AllowDelete`), and
  never this machine or a replace. An emptied or damaged ledger can no longer turn into a
  plan that destroys the DCs.

Known gaps: a reset command for a failed phase; Terraform's
"-state is deprecated" warning (harmless).

## v1.3 (Oct 2026): smaller footprint

Less RAM and disk for the same lab. No site has to change `site.yaml`, unless its VM
storage can't do linked clones (then add `proxmox.clone_mode: full`), so this is a
minor version.

Changed:
- **Right-sized VMs**: DC 4 GB RAM / 50 GB disk (was 8 GB / 80 GB), ADES 6 GB (was 8 GB).
  Phase 1 peak RAM 32 GB → 24 GB; full lab 44 GB → 34 GB.
- **Linked clones**: VMs are linked clones of their template, storing only their changes.
  Needs LVM-thin, ZFS or Ceph RBD with templates and VMs on the same storage; checked by
  validation, the live pre-flight and `proxmox-setup.sh check`. `proxmox.clone_mode: full`
  in site.yaml keeps full clones. The mode is recorded per instance in the ledger
  (`clone_mode`), so changing it later only affects new VMs. On node-local storage,
  linked clones can't migrate to another node.
- **Versioned templates**: each `Build-LabTemplate.ps1` run creates a new version
  (`<family>-<YYMMDD>-<NN>`) in the family's VMID range (WIN2022 +100–123, WIN11
  +124–147) instead of replacing the template. Each instance is pinned to the version it
  was cloned from (`template_vmid` in the ledger); unused superseded versions are deleted
  automatically. lab.yaml: template `vmid_offset` → `vmid_offsets: { first, last }`.

Added:
- **Memory ballooning**: `memory_min_mb` per role (floor), Terraform sets it as the
  balloon minimum; templates install and enable the VirtIO balloon service; MGMT-00 is
  created with ballooning. New validation `MEM-001` (Low).
- Ledger `templates:` list and validation of template versions and pins.
- Validation: a role's `disk_gb` can't be smaller than its template's (clones can't shrink).

Deferred: Server Core for DCs (see docs/decisions.md).

## v1.2 (Oct 2026): portable

The repo can be handed to another engineer and built on their own Proxmox, domain
and Microsoft 365 tenant, with everything else the same.

**Breaking for v1.1 inventories** (no v1.1 site was ever deployed, so this stays a
minor version):
- Per-site settings moved out of `inventory/lab.yaml` into **`inventory/site.yaml`**
  (domains, administrators, subnet, gateway, DNS forwarders, NTP, Proxmox node,
  endpoint, bridge, storages, VMID base, ISO names). `site.template.yaml` is the blank
  copy; the shipped `site.yaml` is an example (`example.com`).
- Addresses are host numbers (`host`) on the site subnet; VMIDs are offsets
  (`vmid_offset`) from the site's `proxmox.vmid_base`.
- The lab subnet must be exactly a /24 network address.

Added:
- `Resolve-LabInventory` / `inventory/resolved/inventory.json`: lab.yaml + site.yaml
  merged; Terraform, Packer and guests read the resolved copy.
- `orchestration/Test-LabSite.ps1`: live pre-flight (Proxmox, storages, bridge, ISOs,
  pool, VMID collisions, lab addresses in use). Build-LabTemplate, Invoke-LabPhase and
  Invoke-LabMgmtRotation run it first.
- `setup/New-LabSiteKit.ps1`: writes `out/site-kit/<site>/RUNBOOK.md` and
  `proxmox-setup.sh` with the site's values filled in.
- `setup/proxmox/proxmox-setup.sh` (replaces `New-ProvisioningAccount.sh`): root-side
  pre-flight, then pool, role, `terraform-prov@pve`, tokens, ACLs and the MGMT-00 VM.
- New validation: placeholders left in `site.yaml`, product keys in `site.yaml` and site
  keys in `lab.yaml`, /24 network address, gateway placement, `vmid_base` ≥ 100, ISOs on
  the ISO storage, Windows (not IANA) time zone IDs, site name, and a ledger that doesn't
  fit the site.
- `docs/NEW-SITE.md` (handoff guide); README requirements (hardware, software, licensing).

Fixed:
- Guests read `inventory.json` as UTF-8 (non-ASCII administrator names).

## v1.1 (Oct 2026)

- AD domain moved off `.local` to a subdomain of an owned domain; lab subnet moved off
  `192.168.1.0/24`.
- Tiered OU structure (`Admin/Tier0|1|2`) and per-object tiers; enforcement deferred.
- Hostnames `<Role>-<YYMMDD>-<NN>` (two-digit year, 15-character limit).
- DC and MGMT slot pools; pipeline replacement of MGMT (Prepare / Complete / Abort).
- Instance ledger (`inventory/instances.yaml`); Terraform guard against destroying
  active instances.

## v1.0

Original architecture document and inventory.
