# Replacing a DC

Windows Server 2022 evaluation editions last 180 days, so each DC is replaced well before
then (each validation report's `EVAL-001` shows the days left), one DC at a time. Replacing
a DC is also how a DC picks up a newer template, and how a broken DC is fixed: the lab
replaces, never repairs.

The replacement is a new DC from the current WIN2022-TEMPLATE version. The forest stays;
only the machines change. Run from the active MGMT, from `C:\MidCoastLab\repo`, in a
PowerShell 7 window (it needn't be elevated: the rotation doesn't change MGMT's DNS, see
below). It asks for the vault's master password when the vault is locked.

**Safety net (optional):** snapshot **both** DCs first, on the node as root
(`qm snapshot <vmid> pre-rotation` for each). On LVM-thin or ZFS a snapshot lives in the
VM's own storage and only stores changes, so it costs little. If you ever revert, revert
both DCs together: reverting one DC alone puts it behind its partner. Delete the snapshots
(`qm delsnapshot <vmid> pre-rotation`) once Retire is done; the retired DC's goes with its VM.

```powershell
./orchestration/Invoke-LabDcRotation.ps1 -Stage Add      # optional: -Replace <DC name>; default the oldest
git -C site add instances.yaml; git -C site commit -m "DC rotation: add"; git -C site push
# ...check anything you like...
./orchestration/Invoke-LabDcRotation.ps1 -Stage Retire
git -C site add instances.yaml; git -C site commit -m "DC rotation: retire"; git -C site push
```

**Add** checks both DCs pass validation, builds `DC-<today>-NN` in the free DC slot as a
replica of the DC that stays, gates on its validation, moves every FSMO role (and with the
PDC emulator, the external time source) from the old DC to the new one, marks the old one
`retiring` and makes sure each DC's DNS client has its fixed list (the other two DC slot
addresses, then loopback; only a DC built before LAB-261127-01 changes). The old DC keeps
running as a third DC; nothing depends on it any more.

**DNS clients don't follow the rotation.** Every lab machine that isn't a DC (MGMT, and
later member roles) uses all three DC slot addresses (`.10`, `.11`, `.12`, slot order), and
each DC uses the other two slots then loopback. The lists never change, so a rotation has
no DNS client to repoint. One slot is empty outside a rotation; Windows moves past a server
that doesn't answer after about a second and then prefers the one that did, so the empty
slot costs an occasional slow lookup, not failures. A MGMT built before LAB-261127-01 still
lists the two DCs that were active when it was built; see the CHANGELOG for the one line
that fixes it.

**Retire** demotes the old DC, removes the DNS records it left behind and its computer
object, and destroys the VM. Terraform may delete exactly that VM and nothing else.

**Abort** (before Retire) undoes Add: the old DC is active again, FSMO roles move back,
and the replacement is demoted and destroyed.

Every stage can be re-run after a failure. `-Force` (Retire/Abort) handles a DC that can't
be reached: its FSMO roles are seized and it's cleaned out of AD (ntdsutil metadata
cleanup) instead of demoted.

The DCs' addresses move: the new DC takes the free slot (`.10`–`.12`), so after a rotation
the lab's DNS servers are different addresses. Anything outside the lab that you pointed at
a DC by hand (a DNS override or forward on the router, Tailscale split DNS, a workstation)
needs updating; Add prints the new addresses. Rotate one DC at a time, and before either
DC's evaluation licence runs out (`EVAL-001`).
