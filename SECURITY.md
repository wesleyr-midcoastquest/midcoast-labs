# Security

MidCoast Lab builds a **lab**: Windows evaluation editions, self-signed certificates,
a Tier 0 management machine that holds the vault. It isn't hardened for production, and
shouldn't be exposed to the internet.

**Reporting a problem:** if you find something that could expose a lab's secrets or let
someone into a lab built with this repo (a script that logs a password, a firewall rule
that's too open, a way around the Terraform guard), please report it privately with
GitHub's **Report a vulnerability** (Security tab), not in a public issue.

**Never commit secrets.** A site's secrets live only in its KeePass vault on MGMT; the
repo's `.gitignore` keeps out the vault (`*.kdbx`), Terraform state and the site folder.
Your own `site/site.yaml` and `site/instances.yaml` describe your lab (domain, subnet,
machine names): keep the site folder's repo private, and run
`tools/Install-LabGitHooks.ps1` in every clone you push from, so its pre-push hook
(`tools/Test-LabPublicTree.ps1`) stops site files, secrets and your private patterns
(`site/deny.txt`) before they leave your machine.
