# Fixing `www`: HTTP-only origin behind Cloudflare

## The situation
- `www.webfranzresume.click` and the apex point to an EC2 server (`54.79.54.68`) that serves **plain HTTP only**.
- In Cloudflare both records are **proxied** (orange cloud).
- Once the zone is Active, visitors reach Cloudflare first, and Cloudflare connects to the EC2 on their behalf. That is where the HTTP-only origin can cause trouble.

I haven't seen your EC2 configuration, so the steps below assume a typical Linux host running nginx or Apache. Adjust the commands to match.

## Quick reference

| Option | Visitor sees | Cloudflare → EC2 | Effort | Use when |
|--------|--------------|------------------|--------|----------|
| **A. Grey cloud (DNS only)** | HTTP, as today | none (direct) | 1 click | You want nothing to change |
| **B. Orange + Flexible** | HTTPS | HTTP (unencrypted) | 2 clicks | Stopgap to get HTTPS fast |
| **C. Certificate on EC2 + Full (strict)** | HTTPS | HTTPS (verified) | ~20 min | The proper fix |

Don't leave the SSL mode on **Full** or **Full (strict)** while the origin is HTTP only. Cloudflare then fails to connect and visitors get **52x** errors (e.g. 525, 526).

`shop` is not affected by any of this. Its traffic goes through the tunnel to a pod inside the cluster, and Cloudflare terminates HTTPS for visitors on its own.

---

## Option A: DNS only (safest, do this first)
1. Cloudflare → **DNS → Records**.
2. Click the orange cloud next to `webfranzresume.click` and `www` so it turns **grey**.
3. Leave `shop` **orange**. It needs the proxy.

Result: `www` behaves exactly as it does today, over HTTP, and nothing depends on the SSL mode.

## Option B: Flexible
1. Cloudflare → **SSL/TLS → Overview** → choose **Flexible**.
2. Keep the records orange.

Result: visitors get HTTPS, but the Cloudflare-to-EC2 leg is plain HTTP and can be read on the way. Treat it as temporary.

**Redirect-loop warning.** If the EC2 redirects HTTP to HTTPS, Flexible creates an endless loop, because Cloudflare always asks the origin over HTTP. Your origin is HTTP-only, so this shouldn't apply, but it will matter after Option C.

## Option C: Proper fix, HTTPS on the origin

### 1. Open port 443
In the EC2 **security group**, allow inbound TCP **443** (and keep 80). Also check any host firewall (`ufw`, `iptables`).

### 2. Get a certificate on the EC2
Two choices.

**C1. Let's Encrypt (publicly trusted, works with Full strict)**
Do this while the records are **grey**, so the validation request reaches the EC2 directly.
```bash
# Debian/Ubuntu with nginx
sudo apt-get update && sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d webfranzresume.click -d www.webfranzresume.click
sudo certbot renew --dry-run          # confirms auto-renewal works
```
Replace `python3-certbot-nginx` with `python3-certbot-apache` for Apache. On Amazon Linux the package names and manager differ.

**C2. Cloudflare Origin Certificate (valid up to 15 years)**
Cloudflare → **SSL/TLS → Origin Server → Create Certificate**. Install the certificate and key on the EC2 and point nginx or Apache at them. Browsers don't trust it directly, so it only works while the records stay **orange**.

### 3. Switch Cloudflare to Full (strict)
1. Turn the records back to **orange**, if you made them grey.
2. **SSL/TLS → Overview → Full (strict)**.
3. Optional: **SSL/TLS → Edge Certificates → Always Use HTTPS** on.

### 4. Test
```bash
curl -I https://www.webfranzresume.click          # 200 or a redirect, no 52x
curl -I http://www.webfranzresume.click           # redirects to https if Always Use HTTPS is on
curl -I https://webfranzresume.click
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 521 | Origin refused the connection or is down | Check that the web server is running and the security group allows the port |
| 522 | Connection timed out | Security group or firewall blocks Cloudflare; confirm the instance is reachable |
| 525 | TLS handshake failed | Mode is Full/Strict but the origin has no HTTPS. Use Flexible or install a cert |
| 526 | Invalid certificate | Mode is Full (strict) with a self-signed or expired cert. Use Let's Encrypt or an Origin Certificate |
| Redirect loop (ERR_TOO_MANY_REDIRECTS) | Flexible mode and the origin redirects to HTTPS | Switch to Full/Strict once the origin has a cert |
| Works only with grey cloud | SSL mode mismatch | Fix the mode per the table above |

## Notes
- **Elastic IP.** `54.79.54.68` is a public address. If it isn't an Elastic IP, it changes when the instance stops and starts, and `www` would break. Check this in the EC2 console.
- **Restricting the origin.** Once proxied, you can restrict the security group to Cloudflare's published IP ranges so nobody can bypass Cloudflare.
- **Order of changes:** Option A now, Option C when you have time, then flip to orange and Full (strict).
- **Interview angle:** SSL modes describe two separate connections: browser to Cloudflare, and Cloudflare to origin. Flexible encrypts only the first. Full (strict) encrypts both and validates the origin certificate.
