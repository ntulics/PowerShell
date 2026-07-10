# Set-ExchangeMaintenanceMode.ps1

An **interactive** PowerShell script that safely places an **Exchange Server 2019
DAG member** into — or takes it out of — **maintenance mode**, including active
database evacuation and post-maintenance redistribution.

It wraps the full, error-prone maintenance-mode sequence (drain transport,
redirect messages, move active databases, suspend the cluster node, block
activation, take the server offline — and the reverse) behind a guided,
menu-driven flow so you don't have to remember and hand-type every cmdlet.

> Run it with **`-WhatIf`** first. That walks the entire flow and shows every
> change it *would* make without altering anything.

---

## What it does

The script auto-detects the server's current state and defaults to the opposite
direction:

### Entering maintenance (`in`)
1. Drains **HubTransport** and restarts the transport services.
2. **Redirects** queued messages to a healthy peer you select.
3. **Evacuates active databases**, either by:
   - *Balancing the DAG* (best available copy per database, by activation
     preference), or
   - *Activating all databases on a specific target server* (optionally setting
     `ActivationPreference = 1` on those copies).
4. **Suspends** the cluster node.
5. Sets `DatabaseCopyActivationDisabledAndMoveNow` and blocks
   `DatabaseCopyAutoActivationPolicy`.
6. Takes the server offline (`ServerWideOffline = Inactive`).

### Exiting maintenance (`out`)
1. Brings the server online (`ServerWideOffline = Active`) and **resumes** the
   cluster node.
2. Re-enables database copy activation and restores the auto-activation policy to
   `Unrestricted`.
3. Re-activates **HubTransport** and restarts transport services.
4. Offers **post-maintenance activation** options:
   - Balance the DAG by activation preference
   - Balance by **site AND** activation preference
   - Prefer a specific **AD site**, then balance
   - Activate **specific databases** back onto this server
   - Skip (leave databases where they are)

## Safety features

- **`-WhatIf` dry run** end-to-end — nothing is changed, every intended action is
  printed.
- **Peer awareness.** Peers that are themselves in maintenance mode are detected
  and **excluded** as redirect/evacuation targets (they can't host active copies
  or accept redirected mail).
- **Confirmation prompts** before entering or exiting maintenance, and before
  bulk activation changes.
- **Action summary** printed at the end, and the window **pauses before exit** so
  you always see the result (it never just disappears).
- Uses Exchange's own **`RedistributeActiveDatabases.ps1`** for balancing when
  available.

## Requirements

- **Exchange Server 2019** with a **Database Availability Group (DAG)**
- Run from an **elevated Windows PowerShell 5.1** session on a server (or
  management workstation) with the **Exchange management tools** installed — or
  from the **Exchange Management Shell**. The script auto-loads the Exchange
  snap-in if it isn't already loaded.
- Appropriate **Exchange RBAC** rights (Organization Management / Server
  Management) and permission to **suspend/resume the failover cluster**.

## Usage

Dry run (recommended first — shows everything, changes nothing):

```powershell
.\Set-ExchangeMaintenanceMode.ps1 -WhatIf
```

Run for real:

```powershell
.\Set-ExchangeMaintenanceMode.ps1
```

The script then:
1. Discovers Exchange servers and lets you **pick one** (shows site + roles).
2. Displays the server's **current maintenance state**.
3. Asks whether to put it **`in`** or take it **`out`** (defaulting to the
   opposite of its current state) and walks you through the rest.

### Parameters

| Parameter | Description |
|-----------|-------------|
| `-WhatIf` | Dry run. Walks the full flow and reports every change it *would* make, without altering anything. |

## Recommendations

- **Always `-WhatIf` first** on a server you haven't run this against before.
- Ensure at least one **healthy peer** exists in the DAG before entering
  maintenance — the script will stop if there is no valid redirect/evacuation
  target.
- After exiting, use one of the **redistribution** options to return databases to
  their preferred owners rather than leaving activation skewed.
- Verify the final state block the script prints, and confirm client connectivity
  before moving on.

## Disclaimer

Provided as-is. This script makes real changes to transport, database activation,
and cluster state. Test with `-WhatIf` and validate in your environment before
using it in production. Nothing is hardcoded — servers, DAG, sites and the
Exchange install path are all discovered at runtime, so it runs unmodified in any
environment.
