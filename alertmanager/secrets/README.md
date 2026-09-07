# Alertmanager secrets

Two files go here, neither committed (`.gitignore` in this folder excludes
the real filenames, keeping only the `.example` templates):

## `smtp_password`
Your Gmail **app password** (not your normal Gmail password — Google
requires 2-Step Verification to be on before it'll let you create one):

1. Turn on 2-Step Verification: https://myaccount.google.com/security
2. Create an app password: https://myaccount.google.com/apppasswords
3. Write it to this file with no quotes, no trailing newline:
   ```bash
   printf '%s' 'your-16-char-app-password' > smtp_password
   ```

Note: this is the same app-password mechanism `msmtp` on the host would
use — but Alertmanager doesn't shell out to `msmtp` or any local mailer. It
has its own built-in SMTP client (`../alertmanager.yml`'s `global.smtp_*`
settings) and talks to `smtp.gmail.com:587` directly. If you also want
`msmtp` on the host for something else (e.g. a quick manual "did this app
password actually work" test), that's independent of this file and not
required for alert emails to send.

## `slack_webhook_url`
A Slack **Incoming Webhook** URL — a different mechanism from the RCA
stage's bot-token approach (`chat:write` scope), and simpler for this:

1. https://api.slack.com/apps → **Create New App** → From scratch
2. Pick the app name + workspace
3. Left sidebar → **Incoming Webhooks** → toggle **Activate Incoming
   Webhooks** on
4. **Add New Webhook to Workspace** → pick the channel (e.g. `#alerts`,
   matching `alertmanager.yml`'s `slack_configs.channel`) → **Allow**
5. Copy the webhook URL it gives you (`https://hooks.slack.com/services/...`)
   into this file:
   ```bash
   printf '%s' 'https://hooks.slack.com/services/...' > slack_webhook_url
   ```

## After creating both files
Also edit `../alertmanager.yml` directly and replace
`REPLACE_WITH_YOUR_GMAIL_ADDRESS` (two places) and
`REPLACE_WITH_DESTINATION_EMAIL` with real addresses — these aren't secret
the way a password is, so they just live in the plain YAML file, not here.

Then recreate the container so it picks up both files and the edited
config:
```bash
docker compose up -d --force-recreate alertmanager
```
