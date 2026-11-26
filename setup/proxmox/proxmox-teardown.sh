#!/usr/bin/env bash
# proxmox-teardown.sh: removes a MidCoast Lab site from Proxmox, so it can be built
# again from scratch. Keeps your ISOs.
#
# Run as root on the lab's node (proxmox.node in site.yaml):
#
#   bash proxmox-teardown.sh --vmid-base 3000            # shows the plan, asks, then removes
#   bash proxmox-teardown.sh --vmid-base 3000 --dry-run  # shows the plan only
#
# A site with its own names (site.yaml proxmox.pool/role/tag/service_account.user,
# 1.6) passes them: --pool --user --role --tag. The defaults are the pre-1.6 names.
# Your RUNBOOK.md ("Starting over") has the full command for your site.
#
# Removes:
#   - every VM in the lab's 150-VMID block (vmid_base .. vmid_base+149) that is the
#     lab's (carrying the lab's tag, or in the lab's pool): clones first, then templates;
#     stopped first, protection cleared, snapshots and disks with them
#   - disks left behind in that block (vm-<id>-*, base-<id>-*) on the VM storages
#   - the pool, the provisioning user (and its API tokens), the role
#   - MGMT-00's answer CD (midcoast-mgmt00-answer.iso) and any root-only secrets file
#     proxmox-setup.sh left behind (/root/midcoast-*-secrets.txt)
#   - with --include-backups: vzdump backups of those VMIDs
# Never touches: a VM in the block that isn't the lab's (it's listed and skipped), any
# other VMID, any other ISO, the storages, bridges or network.
# Keeps (1.7): templates that another lab's VMs are linked clones of (that lab borrows
# them, site.yaml templates.shared_from), and the pool while it holds them. Proxmox
# can't delete a template with linked clones anyway; the plan says who uses which.
#
# Outside Proxmox (not done here): remove the lab's machines in the Tailscale admin
# console, and anything you pointed at lab addresses by hand (router DNS, DHCP leases).
set -euo pipefail

POOL="MidCoast-Lab"
USER_ID="terraform-prov@pve"
ROLE="MidCoastProvisioner"
TAG="midcoast-lab"
ANSWER_ISO="midcoast-mgmt00-answer.iso"
VMID_BASE=""
DRY_RUN=0
ASSUME_YES=0
INCLUDE_BACKUPS=0

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid-base)        VMID_BASE="$2"; shift 2 ;;
    --pool)             POOL="$2"; shift 2 ;;
    --user)             USER_ID="$2"; shift 2 ;;
    --role)             ROLE="$2"; shift 2 ;;
    --tag)              TAG="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --yes)              ASSUME_YES=1; shift ;;
    --include-backups)  INCLUDE_BACKUPS=1; shift ;;
    -h|--help)          usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
done
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root." >&2; exit 2; }
[[ "$VMID_BASE" =~ ^[0-9]+$ && "$VMID_BASE" -ge 100 ]] || { echo "Give --vmid-base (site.yaml proxmox.vmid_base, e.g. 3000)." >&2; exit 2; }
FIRST=$VMID_BASE; LAST=$((VMID_BASE + 149))

json() { python3 -c "$1"; }

# ── Discover ──────────────────────────────────────────────────────────────
echo "==> MidCoast Lab teardown: VMIDs $FIRST-$LAST, pool $POOL, tag $TAG, user $USER_ID, role $ROLE"
VMS_JSON="$(pvesh get /cluster/resources --type vm --output-format json)"
# lines: vmid node template(0/1) status name ours(0/1)
VM_LINES="$(FIRST=$FIRST LAST=$LAST POOL="$POOL" TAG="$TAG" VMS="$VMS_JSON" python3 - <<'PY'
import json, os
first, last, pool = int(os.environ["FIRST"]), int(os.environ["LAST"]), os.environ["POOL"]
for v in sorted(json.loads(os.environ["VMS"]), key=lambda v: (int(v.get("template", 0)), int(v["vmid"]))):
    vid = int(v["vmid"])
    if not (first <= vid <= last):
        continue
    tags = [t for t in str(v.get("tags", "")).replace(",", ";").replace(" ", ";").split(";") if t]
    ours = 1 if (os.environ["TAG"] in tags or v.get("pool") == pool) else 0
    print(vid, v.get("node", "?"), int(v.get("template", 0)), v.get("status", "?"), v.get("name", "?").replace(" ", "_"), ours)
PY
)"
# Templates in the block that VMs outside it are linked clones of (lines: template clone_vmid clone_name clone_pool).
BORROWED="$(FIRST=$FIRST LAST=$LAST VMS="$VMS_JSON" python3 - <<'PY'
import json, os, re, subprocess
first, last = int(os.environ["FIRST"]), int(os.environ["LAST"])
vms = json.loads(os.environ["VMS"])
for v in vms:
    vid = int(v["vmid"])
    if first <= vid <= last or v.get("type", "qemu") != "qemu":
        continue
    r = subprocess.run(["pvesh", "get", f"/nodes/{v['node']}/qemu/{vid}/config", "--output-format", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        continue
    for val in json.loads(r.stdout).values():
        for t in re.findall(r"base-(\d+)-disk", str(val)):
            if first <= int(t) <= last:
                print(t, vid, str(v.get("name", "?")).replace(" ", "_"), v.get("pool", "-"))
PY
)"
REMOVE=(); SKIP=(); KEPT=()
while read -r vid node tpl status name ours; do
  [[ -z "${vid:-}" ]] && continue
  if [[ "$ours" == "1" && "$tpl" == "1" ]] && awk -v t="$vid" '$1 == t { found = 1 } END { exit !found }' <<< "$BORROWED"; then
    KEPT+=("$vid $name"); continue
  fi
  if [[ "$ours" == "1" ]]; then REMOVE+=("$vid $node $tpl $status $name"); else SKIP+=("$vid $node $name"); fi
done <<< "$VM_LINES"

POOL_EXISTS=0; pveum pool list --output-format json | json "import json,sys; sys.exit(0 if any(p['poolid']=='$POOL' for p in json.load(sys.stdin)) else 1)" && POOL_EXISTS=1 || true
USER_EXISTS=0; pveum user list --output-format json | json "import json,sys; sys.exit(0 if any(u['userid']=='$USER_ID' for u in json.load(sys.stdin)) else 1)" && USER_EXISTS=1 || true
ROLE_EXISTS=0; pveum role list --output-format json | json "import json,sys; sys.exit(0 if any(r['roleid']=='$ROLE' for r in json.load(sys.stdin)) else 1)" && ROLE_EXISTS=1 || true

# Storages on this node: image storages (orphan disks), ISO storages (answer CD), backup storages.
NODE="$(hostname)"
STORAGES_JSON="$(pvesh get /nodes/"$NODE"/storage --output-format json 2>/dev/null || echo '[]')"
storages_with() { STJ="$STORAGES_JSON" C="$1" python3 -c "import json,os; print(' '.join(s['storage'] for s in json.loads(os.environ['STJ']) if os.environ['C'] in str(s.get('content','')).split(',') and s.get('active',1)))"; }
IMG_STORAGES="$(storages_with images)"; ISO_STORAGES="$(storages_with iso)"; BAK_STORAGES="$(storages_with backup)"

ANSWER_VOLS=()
for s in $ISO_STORAGES; do
  if pvesm list "$s" --content iso 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$s:iso/$ANSWER_ISO"; then ANSWER_VOLS+=("$s:iso/$ANSWER_ISO"); fi
done
SECRET_FILES=(); for f in /root/midcoast-*-secrets.txt; do [[ -f "$f" ]] && SECRET_FILES+=("$f"); done
BACKUP_VOLS=()
if [[ "$INCLUDE_BACKUPS" == "1" ]]; then
  for s in $BAK_STORAGES; do
    while read -r vol; do
      id="$(sed -nE 's#.*vzdump-qemu-([0-9]+)-.*#\1#p' <<< "$vol")"
      [[ -n "$id" && "$id" -ge "$FIRST" && "$id" -le "$LAST" ]] && BACKUP_VOLS+=("$vol")
    done < <(pvesm list "$s" --content backup 2>/dev/null | awk 'NR>1 {print $1}')
  done
fi

# ── Plan ──────────────────────────────────────────────────────────────────
echo
echo "Will remove:"
if [[ ${#REMOVE[@]} -eq 0 ]]; then echo "  VMs: none found"; else
  for r in "${REMOVE[@]}"; do read -r vid node tpl status name <<< "$r"
    printf "  VM %-5s %-30s on %-10s %s%s\n" "$vid" "$name" "$node" "$status" "$([[ $tpl == 1 ]] && echo ' (template)')"; done; fi
echo "  disks left behind in $FIRST-$LAST on: ${IMG_STORAGES:-none} (checked after the VMs are gone)"
[[ $POOL_EXISTS == 1 ]] && echo "  pool $POOL"
[[ $USER_EXISTS == 1 ]] && echo "  user $USER_ID (and its API tokens)"
[[ $ROLE_EXISTS == 1 ]] && echo "  role $ROLE"
for v in "${ANSWER_VOLS[@]}"; do echo "  answer CD $v"; done
for f in "${SECRET_FILES[@]}"; do echo "  secrets file $f"; done
if [[ "$INCLUDE_BACKUPS" == "1" ]]; then
  if [[ ${#BACKUP_VOLS[@]} -eq 0 ]]; then echo "  backups: none of these VMIDs"; else for b in "${BACKUP_VOLS[@]}"; do echo "  backup $b"; done; fi
else
  echo "  (backups of these VMIDs are kept; add --include-backups to remove them)"
fi
if [[ ${#SKIP[@]} -gt 0 ]]; then
  echo
  echo "Skipped (in the lab's VMID block but NOT the lab's; check them yourself):"
  for s in "${SKIP[@]}"; do echo "  VM $s"; done
fi
if [[ ${#KEPT[@]} -gt 0 ]]; then
  echo
  echo "Kept: templates other labs' VMs are linked clones of (those labs borrow this lab's templates):"
  for k in "${KEPT[@]}"; do read -r vid name <<< "$k"
    users="$(awk -v t="$vid" '$1 == t { printf "%s%s (VMID %s, pool %s)", sep, $3, $2, $4; sep = ", " }' <<< "$BORROWED")"
    echo "  VM $vid $name, used by $users"
  done
  [[ $POOL_EXISTS == 1 ]] && echo "  and the pool $POOL, which holds them"
  echo "  They go once those VMs are rotated onto another lab's templates or removed; run this again then."
fi
echo
echo "Kept: every ISO except the answer CD, the storages, the network."

[[ "$DRY_RUN" == "1" ]] && { echo; echo "Dry run: nothing changed."; exit 0; }
if [[ "$ASSUME_YES" != "1" ]]; then
  echo
  read -r -p "This can't be undone. Type DESTROY to continue: " answer
  [[ "$answer" == "DESTROY" ]] || { echo "Nothing changed."; exit 1; }
fi

# ── Remove ────────────────────────────────────────────────────────────────
FAILED=0
wait_task() { # pvesh returns a UPID for async tasks; wait for it
  local node="$1" upid="$2" s
  [[ "$upid" == UPID:* ]] || return 0
  for _ in $(seq 1 600); do
    s="$(pvesh get "/nodes/$node/tasks/$upid/status" --output-format json | json "import json,sys; d=json.load(sys.stdin); print(d.get('status'), d.get('exitstatus',''))")"
    [[ "$s" == stopped* ]] && { [[ "$s" == "stopped OK" ]] && return 0 || { echo "    task ended: ${s#stopped }"; return 1; }; }
    sleep 2
  done
  echo "    task timed out"; return 1
}
for r in "${REMOVE[@]}"; do read -r vid node tpl status name <<< "$r"
  echo "==> VM $vid ($name)"
  if [[ "$status" == "running" ]]; then
    echo "    stopping"
    upid="$(pvesh create "/nodes/$node/qemu/$vid/status/stop" --output-format json 2>/dev/null | tr -d '"' || true)"
    wait_task "$node" "$upid" || true
  fi
  pvesh set "/nodes/$node/qemu/$vid/config" --protection 0 >/dev/null 2>&1 || true
  upid="$(pvesh delete "/nodes/$node/qemu/$vid" --purge 1 --destroy-unreferenced-disks 1 --output-format json 2>&1 | tr -d '"' || true)"
  if wait_task "$node" "$upid" && ! pvesh get "/nodes/$node/qemu/$vid/status/current" >/dev/null 2>&1; then
    echo "    destroyed"
  else
    echo "    NOT destroyed: $upid"; FAILED=$((FAILED + 1))
  fi
done

echo "==> Disks left behind in $FIRST-$LAST"
LEFT="$(pvesh get /cluster/resources --type vm --output-format json)"
for s in $IMG_STORAGES; do
  while read -r vol; do
    id="$(sed -nE 's#.*[:/](vm|base)-([0-9]+)-.*#\2#p' <<< "$vol")"
    [[ -z "$id" || "$id" -lt "$FIRST" || "$id" -gt "$LAST" ]] && continue
    # Only if no VM with that ID exists any more (a skipped, non-lab VM keeps its disks).
    if V="$LEFT" I="$id" python3 -c "import json,os,sys; sys.exit(0 if any(int(v['vmid'])==int(os.environ['I']) for v in json.loads(os.environ['V'])) else 1)"; then continue; fi
    if pvesm free "$vol" >/dev/null 2>&1; then echo "    freed $vol"; else echo "    couldn't free $vol"; FAILED=$((FAILED + 1)); fi
  done < <(pvesm list "$s" --content images 2>/dev/null | awk 'NR>1 {print $1}')
done

if [[ $USER_EXISTS == 1 ]]; then echo "==> User $USER_ID"; pveum user delete "$USER_ID" && echo "    removed (with its tokens and ACLs)" || FAILED=$((FAILED + 1)); fi
if [[ $ROLE_EXISTS == 1 ]]; then echo "==> Role $ROLE"; pveum role delete "$ROLE" && echo "    removed" || FAILED=$((FAILED + 1)); fi
if [[ $POOL_EXISTS == 1 && ${#KEPT[@]} -gt 0 ]]; then
  echo "==> Pool $POOL: kept, it holds the templates other labs still use"
elif [[ $POOL_EXISTS == 1 ]]; then
  echo "==> Pool $POOL"
  if pveum pool delete "$POOL" 2>/dev/null; then echo "    removed"; else echo "    not removed (not empty? see: pvesh get /pools/$POOL)"; FAILED=$((FAILED + 1)); fi
fi
for v in "${ANSWER_VOLS[@]}"; do echo "==> $v"; pvesm free "$v" && echo "    removed" || FAILED=$((FAILED + 1)); done
for f in "${SECRET_FILES[@]}"; do echo "==> $f"; shred -u "$f" && echo "    shredded" || FAILED=$((FAILED + 1)); done
for b in "${BACKUP_VOLS[@]}"; do echo "==> $b"; pvesm free "$b" && echo "    removed" || FAILED=$((FAILED + 1)); done

echo
echo "==> Check"
REST="$(FIRST=$FIRST LAST=$LAST V="$(pvesh get /cluster/resources --type vm --output-format json)" python3 -c "import json,os; f,l=int(os.environ['FIRST']),int(os.environ['LAST']); print(' '.join(str(v['vmid']) for v in json.loads(os.environ['V']) if f<=int(v['vmid'])<=l))")"
echo "  VMs left in $FIRST-$LAST: ${REST:-none}"
ACL_LEFT="$(pveum acl list --output-format json | json "import json,sys; print(len([a for a in json.load(sys.stdin) if a.get('ugid')=='$USER_ID' or a.get('roleid')=='$ROLE']))")"
echo "  ACL entries for $USER_ID / $ROLE: $ACL_LEFT"
if [[ $FAILED -gt 0 ]]; then
  echo "Finished with $FAILED problem(s) above; re-run to retry (it only removes what's still there)."; exit 1
fi
if [[ ${#KEPT[@]} -gt 0 ]]; then echo "Done, apart from ${#KEPT[@]} template(s) other labs still use (listed above). ISOs kept."
else echo "Done. Proxmox is clear of the lab; ISOs kept."; fi
echo "Still to do outside Proxmox:"
echo "  - The ledger (inventory/instances.yaml in your repo) and the Terraform state still describe"
echo "    the lab you just removed, and the pipeline would refuse to build. On the machine that runs"
echo "    the pipeline next (after Initialize-LabRepo.ps1 on a new MGMT-00):"
echo "        ./orchestration/Reset-LabLedger.ps1"
echo "  - Remove the lab's machines in the Tailscale admin console."
