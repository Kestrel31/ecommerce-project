# DNS: Cloudflare, AWS Route 53 and the domain

> **Status: resolved.** After the registrar's list was reduced to Cloudflare's two nameservers, the zone became Active and both `shop.webfranzresume.click` and `www.webfranzresume.click` load.

How `webfranzresume.click` is wired together, what each piece does, and the mistakes that kept the Cloudflare zone stuck on "pending". Written from this project's setup and troubleshooting.

## 1. Three separate jobs

People say "domain" for three different things. In this project they live in different places.

| Job | What it does | Where it lives for this project |
|-----|--------------|---------------------------------|
| **Registrar** | Owns the name `webfranzresume.click` and tells the internet which nameservers to ask | AWS Route 53 → *Registered domains* |
| **DNS hosting** | Holds the records (`www`, `shop`) and answers queries | Cloudflare (new), Route 53 hosted zone (old) |
| **Origin** | The server that serves the content | `www` → EC2 `54.79.54.68`; `shop` → the K3s VM via the tunnel |

Buying the domain at AWS made AWS the registrar. It did not force AWS to host the DNS. You can keep the registrar at AWS and host DNS at Cloudflare.

## 2. How a lookup works

```
Browser
  │ 1. "What is shop.webfranzresume.click?"
  ▼
Recursive resolver (your ISP, 1.1.1.1, 8.8.8.8)
  │ 2. Asks the root servers, which point to the .click servers
  ▼
.click registry
  │ 3. "Ask these nameservers for webfranzresume.click" ← the registrar's nameserver list
  ▼
Nameserver listed there (Cloudflare or AWS)
  │ 4. Returns the record
  ▼
Browser connects to the answer
```

Step 3 is the key. The **nameserver list stored at the registrar** decides which DNS host is authoritative. Whatever that list says wins. The records inside a DNS host only matter if that host is on the list.

## 3. The two lists that confused us

Route 53 shows nameservers in two places that look similar and are unrelated.

| Place | Where in the console | What it is | Does the internet read it? |
|-------|----------------------|-----------|---------------------------|
| **Hosted zone NS record** | *Route 53 → Hosted zones → domain* | A record inside your old DNS zone. Always lists four `awsdns` servers. | No, not once you've moved away from that zone |
| **Registered domain nameservers** | *Route 53 → Domains → Registered domains → domain → Name servers* | The list sent to the `.click` registry | **Yes. This is the one that matters** |

Editing the hosted zone's NS record changes nothing about who answers. To move DNS to Cloudflare, edit the registered domain's list.

## 4. What went wrong here

The registered domain listed **six** nameservers: Cloudflare's `audrey` and `dion`, plus the four old `awsdns` servers. `whois` showed it:

```
Name Server: dion.ns.cloudflare.com
Name Server: audrey.ns.cloudflare.com
Name Server: ns-792.awsdns-35.net
Name Server: ns-92.awsdns-11.com
Name Server: ns-1703.awsdns-20.co.uk
Name Server: ns-1374.awsdns-43.org
```

Consequences:
- Cloudflare only activates a zone when the registrar lists **only** its two assigned nameservers. Extra servers keep the status at `pending`, shown as "invalid nameserver".
- Resolvers pick from the full list. Some answers came from Cloudflare and some from Route 53. That is why `8.8.8.8` returned Cloudflare servers at one moment and AWS servers the next.
- `shop` exists only in Cloudflare, so it failed to resolve whenever a resolver asked an AWS server.

### Misleading signals we ran into
| Signal | What it really meant |
|--------|---------------------|
| `original_name_servers` listed AWS in Cloudflare's API output | Only a record of what the domain used when added to Cloudflare. It routes nothing. |
| `dig` showed `audrey` and `dion` | Showed one resolver's answer, possibly cached. It did not prove the registrar list was clean. |
| `dig` timed out against `1.1.1.1` / `8.8.8.8` on the VPN | The corporate network blocked outbound DNS. Unrelated to the domain. |
| `dig shop...` returned a `.cfargotunnel.com` name | The zone wasn't Active, so the record wasn't proxied and showed its raw target. |
| `whois` | **The reliable check.** It reads the registry, not a cache. |

## 5. Moving DNS to Cloudflare, step by step

1. **Add the domain in Cloudflare.** It assigns a pair of nameservers (here `audrey` and `dion`).
2. **Recreate every record in Cloudflare** before switching. Compare against the Route 53 hosted zone. Ignore NS and SOA. Copy A, CNAME, MX and TXT records. This domain had only the apex and `www` A records, both `54.79.54.68`.
3. **Set non-tunnel records to DNS only (grey cloud)** to keep behavior unchanged. Enable the proxy later, after picking an SSL mode.
4. **At the registrar** (*Route 53 → Registered domains → Edit name servers*), replace the whole list with Cloudflare's two. Delete the `awsdns` entries.
5. If DNSSEC is enabled, disable it first and wait for the DS record's TTL to expire. Here it was `unsigned`, so it wasn't an issue.
6. **Verify with `whois`**, then click **Check nameservers now** in Cloudflare.
7. The zone changes from `pending` to `active`.

## 6. Proxied vs DNS only

| Mode | Cloudflare icon | What visitors reach | Used for |
|------|-----------------|---------------------|----------|
| **Proxied** | Orange cloud | Cloudflare's edge, which forwards to the origin. The origin IP is hidden. | `shop` (required for tunnels) |
| **DNS only** | Grey cloud | The origin IP directly | `www` / apex, until an SSL mode is chosen |

When you proxy an origin like the EC2, Cloudflare connects to it over HTTP or HTTPS, depending on the SSL/TLS mode:

| Origin | Mode that works | Failure if wrong |
|--------|-----------------|------------------|
| HTTP only | Flexible | 525/526 with Full |
| HTTPS, self-signed cert | Full | 526 with Full (strict) |
| HTTPS, valid cert | Full (strict) | |
| Origin redirects HTTP → HTTPS | Not Flexible | Redirect loop |

The EC2 security group must also allow Cloudflare to reach the port it uses.

## 7. How the `shop` tunnel fits in

```
Browser ─► Cloudflare edge ─► tunnel ◄── cloudflared pod (outbound) ─► frontend.web:8080
```
- A tunnel is addressed by ID: `<tunnel-id>.cfargotunnel.com`.
- `cfargotunnel.com` is Cloudflare's own domain for tunnel endpoints. It only works as a **proxied CNAME target** inside a Cloudflare zone, and it isn't publicly resolvable.
- The DNS record is the link between a hostname and a tunnel. A stale record can point at a tunnel that no longer exists.
- Terraform creates only the `shop` CNAME. The `www` and apex records are untouched.
- `cloudflared` makes an **outbound** connection, so no ports are opened on the VM, and it works behind NAT.

**Tunnel gotcha from this project.** An earlier `apply` created a `shop` record pointing at one tunnel (`896f2ce1...`), while Terraform's state held a different tunnel (`47f861eb...`). Importing the record would have aimed `shop` at the wrong tunnel. The fix was to compare the IDs, delete the stale record and re-apply.

## 8. Zone status

| Status | Meaning |
|--------|---------|
| `pending` | Cloudflare hasn't confirmed the registrar's nameserver list. Proxied records aren't served. |
| `active` | The registrar lists exactly Cloudflare's pair. Records and the proxy work. |

The tunnel and `cloudflared` can be healthy while the zone is pending. Only DNS resolution fails, with `curl: (6) Could not resolve host`.

## 9. Diagnostic commands

```bash
# What the registry says (authoritative; best check)
whois webfranzresume.click | grep -iE "name server|dnssec"

# What a resolver returns (can be cached)
dig NS webfranzresume.click @1.1.1.1 +short

# What the record resolves to; proxied records return Cloudflare IPs (104.x / 172.67.x)
dig shop.webfranzresume.click @1.1.1.1 +short

# Zone status and expected nameservers (token needs Zone read)
curl -s -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
  "https://api.cloudflare.com/client/v4/zones/<zone_id>" \
  | jq '.result | {name, status, name_servers, original_name_servers}'

# List DNS records
curl -s -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
  "https://api.cloudflare.com/client/v4/zones/<zone_id>/dns_records" \
  | jq '.result[] | {name, type, content, proxied}'
```
Never paste the token into chat, tickets or git.

## 10. Caching and propagation

- Delegation records at the TLD are cached for up to 48 hours. Resolvers that cached the old nameservers keep answering with them until the TTL expires.
- Changing the registrar again restarts nothing useful, so fix it once and wait.
- Cloudflare re-checks pending zones on its own, often every few hours at first.
- Corporate VPNs may block outbound DNS to anything but their own resolver. Test from the VM or off the VPN.

## 11. API token notes

- Scope tokens narrowly. Terraform here needs *Account → Cloudflare Tunnel → Edit* and *Zone → DNS → Edit*.
- Calls outside that scope fail with `9109 Unauthorized`. For example, the activation check needs more rights, so use the dashboard button instead of widening the token.
- A token pasted into chat is exposed, so roll it. This happened once during the project and the token was rolled.

## 12. Rollback

The Route 53 hosted zone isn't deleted by any of the above. If `www` breaks after the switch, add the four AWS nameservers back at the registrar. Keep the hosted zone for a few days, then delete it to stop the roughly $0.50 per month charge.

## Interview talking points

- **Registrar vs DNS host vs origin** are three different roles that can all be at different providers.
- **The registrar's nameserver list is authoritative.** Records only matter on a host that's on the list.
- **Diagnosis:** the symptoms (flapping answers, pending zone) came from a mixed nameserver list, and `whois` exposed it when `dig` couldn't. Cached resolvers make `dig` an unreliable check.
- **Migrating DNS safely:** copy all records first, keep behavior unchanged with DNS-only, switch the list, verify with `whois`, and keep the old zone for rollback.
- **Tunnels:** addressed by ID, linked to hostnames by a proxied CNAME, with outbound-only connectivity.
