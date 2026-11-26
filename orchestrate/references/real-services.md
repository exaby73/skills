# Testing Against Real Services

Some behaviour only shows against the real thing: an identity provider, a payment provider, an email service. Test it with a local copy of the project pointed at the service's real test tenant or sandbox account, not on a preview deploy, so you can read the logs, change the code, and rerun in minutes.

1. Run the project locally with its settings pointed at the test tenant. Take the tenant's secrets as [secrets.md](secrets.md) says.
2. Open the local copy in the preview browser, and ask the owner to sign in there once, themselves. Reuse that session for every run after; never ask them for a password in chat.
3. Walk each flow end to end, and check what the service received as well as what the project shows.
4. Write the result as a dated record, `docs/qualification/<topic>-YYYY-MM-DD.md`: what ran, against which tenant, and what it found. File an issue for each failure.

Stop and ask the owner before anything that touches a production tenant, sends to real people, or costs money.
