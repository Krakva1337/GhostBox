# Void Linux / runit

This is the initial service layout for x86_64. The Flutter UI currently starts
the selected core directly for development. The runit service is reserved for
the privileged system integration layer (TUN setup, DNS and firewall policy).

Install the service after packaging the native helper:

```sh
install -d /etc/sv/ghostbox/log /var/log/ghostbox
cp deploy/runit/ghostbox/run /etc/sv/ghostbox/run
cp deploy/runit/ghostbox/log/run /etc/sv/ghostbox/log/run
chmod +x /etc/sv/ghostbox/run /etc/sv/ghostbox/log/run
ln -s /etc/sv/ghostbox /var/service/ghostbox
```

Do not run the Flutter GUI as root. The future `ghostbox_core` helper should
own the only privileged operations and expose a narrow local IPC API.
