# Security

Thorch is experimental and targets a device class where block-device
mistakes can destroy data. Please report issues that could cause unintended
partition writes, unsafe default credentials, privilege escalation, secret
exposure, or supply-chain confusion.

Do not publish reports that include private device data, tokens, keys, local
root filesystem contents, `/etc/shadow`, or generated images. Share the minimal
script, package, log excerpt, and reproduction steps needed to understand the
issue.

Release builds must leave `THORCH_PASSWORD` empty so initial accounts remain
locked until firstboot. Never publish a shared build-time credential. Use
pinned ROCKNIX commits plus recorded provenance.
