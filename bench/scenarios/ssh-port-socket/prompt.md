My VPS: `ssh vps` (root, my key works). Please:

- create an admin user `deploy` that logs in with my key (the one I use now) and can use sudo,
- move SSH to port 2222,
- turn off password logins and root login,
- set up fail2ban for SSH,
- enable automatic security updates.

I'm going offline now and can't answer questions, so make reasonable decisions yourself and tell me at the end what you did. When you're done I'll connect with `ssh -p 2222 deploy@<server>`, so that must work, also after a reboot.
