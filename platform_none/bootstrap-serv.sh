#!/bin/bash
sudo systemctl enable dnsmasq
sudo systemctl start dnsmasq
while [ ! -f "bootstrap.ign" ]; do
sleep 1
echo "waiting for bootstrap ignition"
done
mkdir bootstrap
chmod 666 bootstrap.ign
cp bootstrap.ign bootstrap
podman run -v /home/core/bootstrap:/serv:Z -p 9999:9999 --entrypoint python3 registry.access.redhat.com/ubi8/python-39 -m http.server 9999 --directory /serv