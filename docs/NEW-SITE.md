# Your site: what to collect, and how to fill in `site.yaml`

This is step 5 of the README's checklist. Everything that differs between one MidCoast
Lab and another is in one file, `inventory/site.yaml`: your domain, your network, your
Proxmox. This page lists what to collect for it, where to find each value, and how to
write it in. Then you go back to the README checklist (step 6) to check it.

Everything else (roles, sizes, host numbers, the OU tree, groups, naming, validation) is
in `inventory/lab.yaml`, the same at every site. You don't edit it.

| Same everywhere (`lab.yaml`) | Yours (`site.yaml`) |
|---|---|
| Roles, CPU/RAM/disk, templates | Site name, time zone |
| Hostnames `<Role>-<YYMMDD>-<NN>` | AD domain and NetBIOS name |
| Host numbers: DCs .10–.12, ADES .20, MGMT .30/.31, W11 .40; lab range .10–.49 | Lab subnet (a /24), gateway, DNS forwarders, NTP |
| VMID offsets: servers +0–99, template versions +100–147, staging +148–149 | `vmid_base` (where your 150-ID block starts) |
| OU tree, tiering, groups, service accounts, LAPS | Entra tenant domain (UPN suffix), your administrators |
| Pool `MidCoast-Lab`, user `terraform-prov@pve`, vault `MidCoastLab` | Proxmox node, endpoint, bridge, storages, ISO names |

## 1. Collect the information

Gather these first; most take a minute in the Proxmox web UI or a root shell on the node.
The last column is where each goes in `site.yaml`.

### You and your site

| What | Where to find it / how to choose | `site.yaml` |
|---|---|---|
| A short name for this lab | Your choice, e.g. `jdoe-lab`. Shown in logs and the site kit | `site.name` |
| Time zone | A **Windows** time zone ID, such as `Eastern Standard Time` (not `America/New_York`): `tzutil /l` on any Windows machine lists them. `UTC` suits a team in several time zones | `site.time_zone` |
| Your administrator account(s) | A username (18 characters or fewer), given name and surname for each. At least one at tier 0. Each gets `<username>` (standard) and `<username>-a` (admin). The name and `<username>@<tenant domain>` also become your git identity on MGMT, so use your real name | `identity.administrators` |

### Domain and tenant

| What | Where to find it / how to choose | `site.yaml` |
|---|---|---|
| Your tenant domain | A domain you own, verified as a custom domain in your Microsoft 365 / Entra tenant (Microsoft 365 admin center → **Settings → Domains**). It becomes every user's UPN suffix, so choose it now: changing it later means re-suffixing every account | `identity.entra.tenant_domain` |
| The AD domain | A subdomain of the tenant domain, usually `ad.<tenant domain>`. **Permanent** for the life of the forest. Never `.local`, never a single label | `identity.active_directory.domain` |
| The NetBIOS name | 15 characters or fewer, no dots, usually your domain's first part in capitals (`EXAMPLE`) | `identity.active_directory.netbios` |

### Network

| What | Where to find it / how to choose | `site.yaml` |
|---|---|---|
| A /24 for the lab | One nothing else uses: not your home LAN, and not another MidCoast lab you might reach over a shared tailnet or VPN. Written as its network address, e.g. `10.88.20.0/24`. Lab machines take fixed addresses in `.10`–`.49` (first DC `.10`, MGMT-00 `.30`) | `network.subnet` |
| The gateway | The router on the lab bridge, usually `.1`, and anywhere outside `.10`–`.49`. Its DHCP must hand out only addresses outside `.10`–`.49` | `network.gateway` |
| Upstream DNS | Where the DCs forward names they don't hold; often the gateway | `network.dns_forwarders` |
| NTP | `pool.ntp.org` works; use your own time source if you have one | `network.ntp` |
| Remote Desktop from elsewhere (optional) | Only if you need to reach MGMT from outside the lab subnet, e.g. your workstation's LAN. Keep it narrow | `network.remote_desktop_from` |

### Proxmox

| What | Where to find it / how to choose | `site.yaml` |
|---|---|---|
| Cluster name | Datacenter → **Cluster** (or `pvecm status`); for a single node, anything. Informational only | `proxmox.cluster` |
| Node | The node the lab runs on: its name in the web UI's tree, or `hostname` on it | `proxmox.node` |
| API endpoint | The address you open the web UI with: `https://<host>:8006/`. The lab subnet must reach it directly (README, Requirements) | `proxmox.endpoint` |
| Certificate | Leave `insecure_tls: true` for Proxmox's default self-signed certificate | `proxmox.insecure_tls` |
| Lab bridge | The node → **System → Network** (or `ip -br link`), e.g. `vmbr2`: the bridge the lab's router is on | `proxmox.bridge` |
| VM storage | Datacenter → **Storage** (or `pvesm status`): one that holds **disk images**, ideally LVM-thin, ZFS or Ceph RBD (`local-lvm`, `local-zfs`). Use the same one for both settings | `proxmox.storage.templates`, `proxmox.storage.virtual_machines` |
| ISO storage | One that holds **ISO images**, usually `local` | `proxmox.storage.iso_repository` |
| A free VMID block | The lab uses 150 IDs from `vmid_base`. List what's taken with `pvesh get /cluster/resources --type vm` (or the web UI's tree) and pick a base with nothing in its 150, e.g. `3000` (servers 3000–3099, templates 3100–3149; MGMT-00 is 3020) | `proxmox.vmid_base` |
| Clone mode | Only if your VM storage is a directory or NFS (no linked clones): `clone_mode: full`, which uses about twice the disk. Decide before the first build | `proxmox.clone_mode` |

One lab per Proxmox cluster: the pool, role and `terraform-prov@pve` user are cluster-wide
names.

### ISOs

| What | Where to find it | `site.yaml` |
|---|---|---|
| The three ISO file names, exactly | Windows Server 2022 evaluation, Windows 11 Enterprise evaluation and `virtio-win.iso`, on the ISO storage: the storage's **ISO Images** tab, or `pvesm list local --content iso`. Not uploaded yet? Use the names you'll upload them under (runbook step 2) | `isos` |

### Tailscale (optional)

| What | How to choose | `site.yaml` |
|---|---|---|
| Whether every lab machine joins your tailnet | Recommended if you use Tailscale for remote access | `tailscale.enabled` |

Only the yes/no goes in `site.yaml`. The **auth key** goes in the vault later (the runbook
asks for it), never in this file. Make it **reusable**, **tagged** (e.g.
`tag:midcoast-lab`) and **not ephemeral** (leave *Ephemeral* off): an ephemeral device is
removed from the tailnet once it's offline for a while and can't rejoin by itself. With
`enabled: true`, runbook step 3 also offers to put MGMT-00 on the tailnet during its
install, with a separate **one-time** key (reusable off) you type at the prompt.

## 2. Fill in `site.yaml`

If you haven't yet, make it from the template, in the repo's folder (README checklist,
step 5):

```powershell
Copy-Item inventory/site.template.yaml inventory/site.yaml
```

Open it in any text editor and replace every `<placeholder>` with what you collected,
**angle brackets included**. The comments in the file say what each one is.

```yaml
# before
    domain: <ad.your-domain>
    netbios: <NETBIOS>
# after
    domain: ad.example.com
    netbios: EXAMPLE
```

A few things to watch:

- **Indentation is meaningful** in YAML: keep the spaces as they are, and use spaces,
  never tabs.
- **ISOs** are written `<iso storage>:iso/<file name>`, e.g.
  `local:iso/virtio-win.iso`.
- **Time zones with spaces** are fine as they are (`time_zone: Eastern Standard Time`).
- **More administrators**: copy the whole `- username:` block, keep its indentation, and
  give each a tier.
- Leave the optional settings (`remote_desktop_from`, `clone_mode`) commented out unless
  you need them.

`inventory/site.example.yaml` is a complete, filled-in example (`example.com`, `pve01`)
to compare with. Don't copy its values: they belong to an imaginary site.

## 3. Back to the README checklist

Next is the README checklist's **step 6**, `Test-LabInventory.ps1`, which checks what
you've written. When it complains:

- **A placeholder remains**: something still has `<…>` in it, brackets included.
- **`.local` or single-label domain**: use a subdomain of your tenant domain.
- **Subnet**: it must be a /24 written as its network address (`10.88.20.0/24`, not
  `10.88.20.1/24`).
- **Gateway**: it must be inside the subnet, and outside `.10`–`.49`.
- **`vmid_base`**: it must be 100 or more.
- **ISOs**: each must be on the storage named in `iso_repository`.
- **A product setting in `site.yaml`**: something that belongs in `lab.yaml` was added;
  remove it.
- **Warning about a common home-router subnet** (`192.168.0.0/24`, `192.168.1.0/24` and
  the like): not an error, but make sure it isn't one your network already uses.

Later, two live checks look at Proxmox and the network itself: `proxmox-setup.sh check`
(runbook step 3) and `Test-LabSite.ps1` (runbook step 7). If they find something already
there:

- **A VMID is taken** by something that isn't this lab: choose another `vmid_base`,
  re-run `New-LabSiteKit.ps1`, and check again. Don't move the other VM to make room.
- **An address is in use**: a device outside the lab answers on a lab address. Move it
  out of `.10`–`.49`, or fix the router's DHCP range.
- **A `MidCoast-Lab` pool or `terraform-prov@pve` user exists**: from an earlier attempt
  at this lab, the setup script updates them in place. From something else, stop: one lab
  per cluster.

Change `site.yaml` any time before the first build. Afterwards, the domain, NetBIOS name
and subnet are fixed for the life of the lab; changing them means starting over (README,
"A lab's lifecycle").
