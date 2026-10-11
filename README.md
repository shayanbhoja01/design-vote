# Design Vote Portal (GitHub Pages + Supabase)

Customers swipe through new designs; you see all the numbers in a private admin page.
Hosting: GitHub Pages (free, static files). Votes and pictures: Supabase.

## Files
| File | Purpose |
|---|---|
| `index.html` | Customer page (the link you share) |
| `admin.html` | Your dashboard: upload, results, export, settings (login required) |
| `config.js` | Supabase URL + public key, brand name, shop link |
| `schema.sql` | Database setup, run once in Supabase SQL Editor |
| `.nojekyll` | Tells GitHub Pages to serve files as they are |

## 1. Supabase (use the account you want for this portal)
1. supabase.com > New project (name `design-vote`, region closest to customers). Save the DB password.
2. SQL Editor > New query > paste all of `schema.sql` > Run ("Success").
3. Authentication > Users > Add user > Create new user (your email + strong password, tick Auto Confirm User).
4. SQL Editor: `insert into admin_users (email) values ('your-email');`
5. Project Settings > API: copy the Project URL and the publishable (anon) key into `config.js`.

## 2. GitHub Pages
1. Create a GitHub repository (Pages on a free account needs a **public** repo; that is fine, see Security).
2. Upload all files in this folder to the repo root (Add file > Upload files), commit.
3. Settings > Pages > Deploy from a branch > `main` / root > Save.
4. After ~1 minute your site is at `https://<username>.github.io/<repo>/`
   - Customers: that link
   - You: that link + `admin.html`

## Security notes
- The publishable/anon key is designed to be public. Protection comes from the database rules in `schema.sql`.
- Never commit the `service_role` key, a database password or an access token.
- Customers cannot read votes or tables; only your admin login can.
- Updating a design list or settings never needs a code change: use the admin page.
