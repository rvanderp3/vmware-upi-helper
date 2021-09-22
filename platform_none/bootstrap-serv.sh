#!/bin/bash
sudo systemctl enable dnsmasq
sudo systemctl start dnsmasq
podman pull registry.access.redhat.com/ubi8/python-39
while [ ! -f "/home/core/bootstrap.ign" ]; do
sleep 1
echo "waiting for bootstrap ignition"
done
mkdir /home/core/bootstrap
chmod 666 /home/core/bootstrap.ign
cp /home/core/bootstrap.ign /home/core/bootstrap
podman run -v /home/core/bootstrap:/serv:Z -p 9999:9999 --entrypoint python3 registry.access.redhat.com/ubi8/python-39 -m http.server 9999 --directory /serv